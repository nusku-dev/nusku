//! The unwind layer: tables that say, for every instruction of the target's binaries, where its
//! caller's frame is. Built from .eh_frame, .debug_frame and .gopclntab, once per binary; what
//! uses them (the kernel programs, through ebpf) reads `tables`. Stands on os, elf and target.

const std = @import("std");
const assert = std.debug.assert;
const elf = @import("elf.zig");
const target = @import("target.zig");
const registry_file = @import("unwind/registry.zig");
const process_table = @import("unwind/process_table.zig");
const log = @import("log.zig").agent;

/// The tables' layout, as the kernel programs read them.
pub const wire = @import("unwind/wire.zig");
/// Why a mapping has no table: the keys of `Coverage.unavailable`.
pub const Cause = registry_file.Cause;

const Registry = registry_file.Registry;
const Outcome = registry_file.Outcome;
const Identity = registry_file.Identity;
const ProcessEntry = wire.ProcessEntry;
const Region = target.Region;
const VdsoImage = target.VdsoImage;

/// Every binary remembered, with a table or without. Four times the modules, because many
/// mapped files (the vDSO, data-only libraries) never get one.
const binaries_max = 4 * wire.modules_max;

/// How well the target's code can be unwound, as of the last sync.
pub const Coverage = struct {
    /// Executable mappings in the target's entry.
    mappings: u32 = 0,
    /// Executable mappings that did not fit in the entry: frames in them cannot be unwound.
    mappings_dropped: u32 = 0,
    /// Mappings without a table, by reason. Their frames fall back to frame pointers.
    unavailable: std.EnumArray(Cause, u32) = .initFill(0),
};

/// What has been built, in the layout the kernel reads. Valid until the next `sync`.
pub const Tables = struct {
    /// Every row, `wire.rows_max` of them: one map value.
    rows: []const wire.Row,
    /// Only grows: a module, once there, never changes.
    modules: []const wire.Module,
    /// The target's mappings, each with its module.
    entry: *const ProcessEntry,
    coverage: Coverage,
};

pub const Unwind = struct {
    registry: Registry,
    /// Built by `sync`. A field rather than a local: it is 16 KiB.
    entry: ProcessEntry,
    /// Where `sync` reads the start of a file to check its build ID.
    prefix_buffer: []u8,
    vdso_image: ?*const VdsoImage,
    coverage: Coverage,

    /// `vdso_image`, the source of every target's [vdso] table, must outlive the tables.
    pub fn init(unwind: *Unwind, gpa: std.mem.Allocator, vdso_image: ?*const VdsoImage) !void {
        unwind.* = .{
            .registry = undefined,
            .entry = std.mem.zeroes(ProcessEntry),
            .prefix_buffer = &.{},
            .vdso_image = vdso_image,
            .coverage = .{},
        };
        try unwind.registry.init(gpa, .{
            .rows_max = wire.rows_max,
            .modules_max = wire.modules_max,
            .binaries_max = binaries_max,
        });
        errdefer unwind.registry.deinit(gpa);
        unwind.prefix_buffer = try gpa.alloc(u8, target.build_id_prefix_size);
        // The rows go to the kernel whole: they have exactly the map value's size.
        assert(unwind.registry.set.rows.len == wire.rows_max);
    }

    pub fn deinit(unwind: *Unwind, gpa: std.mem.Allocator) void {
        gpa.free(unwind.prefix_buffer);
        unwind.registry.deinit(gpa);
        unwind.* = undefined;
    }

    /// Builds the tables of the binaries in `regions` met for the first time, and the entry.
    pub fn sync(unwind: *Unwind, gpa: std.mem.Allocator, pid: u32, regions: []const Region) !void {
        assert(pid > 0);
        const coverage = try entry_build(.{
            .gpa = gpa,
            .registry = &unwind.registry,
            .prefix_buffer = unwind.prefix_buffer,
            .vdso_image = unwind.vdso_image,
            .pid = pid,
        }, regions, &unwind.entry);
        if (!std.meta.eql(coverage, unwind.coverage)) coverage_log(&coverage);
        unwind.coverage = coverage;
    }

    pub fn tables(unwind: *const Unwind) Tables {
        const set = &unwind.registry.set;
        return .{
            .rows = set.rows,
            .modules = set.modules[0..set.modules_count],
            .entry = &unwind.entry,
            .coverage = unwind.coverage,
        };
    }
};

/// How much of the target can be unwound, logged when it changes: at the start, and when the
/// target maps or unmaps code.
fn coverage_log(coverage: *const Coverage) void {
    var without_table: u32 = 0;
    for (coverage.unavailable.values) |count| without_table += count;
    log.info("unwind coverage", .{
        .mappings = coverage.mappings,
        .with_table = coverage.mappings - without_table,
        .without_table = without_table,
        .dropped = coverage.mappings_dropped,
    });
    if (coverage.mappings_dropped > 0) {
        log.warn("the target maps more code than fits: frames there cannot be unwound", .{
            .mappings_max = wire.mappings_max,
            .dropped = coverage.mappings_dropped,
        });
    }
}

/// What building an entry needs besides the regions.
const BuildContext = struct {
    gpa: std.mem.Allocator,
    registry: *Registry,
    /// Where the start of a file is read to check its build ID.
    prefix_buffer: []u8,
    vdso_image: ?*const VdsoImage,
    pid: u32,
};

/// Fills `entry` with the target's mappings and the outcome of each one's binary, building the
/// tables of binaries not met before.
fn entry_build(context: BuildContext, regions: []const Region, entry: *ProcessEntry) !Coverage {
    var coverage = Coverage{};
    var builder = process_table.Builder.init(entry);
    for (regions) |*region| {
        const outcome = try outcome_for(context, region);
        switch (outcome) {
            .loaded => {},
            .unavailable => |cause| coverage.unavailable.getPtr(cause).* += 1,
        }
        try builder.add(.{
            .start = region.start,
            .end = region.end,
            .offset = region.offset,
            .outcome = outcome,
        });
    }
    coverage.mappings = entry.count;
    coverage.mappings_dropped = entry.dropped;
    assert(coverage.mappings + coverage.mappings_dropped == regions.len);
    return coverage;
}

/// The table of the binary behind `region`: remembered, or built now.
fn outcome_for(context: BuildContext, region: *const Region) !Outcome {
    if (std.mem.eql(u8, region.path, target.vdso_path)) return outcome_for_vdso(context, region);
    // Anonymous code (JIT) and the other special mappings have no file to read.
    if (region.path.len == 0) return .{ .unavailable = .unreadable };
    if (region.path[0] != '/') return .{ .unavailable = .unreadable };

    const identity = identity_of(region);
    if (context.registry.lookup(identity)) |known| return known;

    // Not remembered when it fails: the next report checks again.
    const opened = target.file_open(context.pid, region, context.prefix_buffer);
    var file = opened catch |err| switch (err) {
        error.Unreadable => return .{ .unavailable = .unreadable },
        error.WrongFile => return .{ .unavailable = .wrong_file },
    };
    defer file.deinit();

    const loading = elf.file.load(&file, &elf.file.sections_unwind, elf.file.file_size_max);
    var loaded = loading catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.debug("binary not readable as ELF", .{ .path = region.path, .cause = err });
            return .{ .unavailable = .unreadable };
        },
    };
    defer loaded.deinit();
    // Only the headers and the unwind sections are read: this says how much that saved.
    log.debug("binary read for unwinding", .{
        .path = region.path,
        .file_kib = loaded.bytes.len / 1024,
        .read_kib = loaded.read_size / 1024,
    });

    const outcome = try context.registry.add(context.gpa, identity, .{
        .file = loaded.bytes,
        .start = region.start,
        .end = region.end,
        .offset = region.offset,
    });
    outcome_log(region, outcome);
    return outcome;
}

/// Logged once per binary: the registry remembers the outcome, so it is not built again.
fn outcome_log(region: *const Region, outcome: Outcome) void {
    switch (outcome) {
        .loaded => |loaded| log.debug("unwind table ready", .{
            .path = region.path,
            .module = loaded.id,
        }),
        .unavailable => |cause| log.debug("no unwind table: frame pointers only", .{
            .path = region.path,
            .cause = cause,
        }),
    }
}

/// The target's vDSO is the agent's own image, if their sizes agree (see target/vdso.zig).
fn outcome_for_vdso(context: BuildContext, region: *const Region) !Outcome {
    assert(std.mem.eql(u8, region.path, target.vdso_path));
    const image = context.vdso_image orelse return .{ .unavailable = .vdso_unknown };
    if (!image.matches(region.end - region.start)) return .{ .unavailable = .vdso_unknown };

    // The vDSO has no inode: without a build ID, its path names it.
    const identity: Identity = if (image.build_id) |id|
        .{ .build_id = id }
    else
        .{ .file = .{ .inode = 0, .path = target.vdso_path } };
    if (context.registry.lookup(identity)) |known| return known;

    const outcome = try context.registry.add(context.gpa, identity, .{
        .file = image.bytes,
        .start = region.start,
        .end = region.end,
        .offset = region.offset,
    });
    outcome_log(region, outcome);
    return outcome;
}

fn identity_of(region: *const Region) Identity {
    if (region.build_id) |id| return .{ .build_id = id };
    return .{ .file = .{ .inode = region.inode, .path = region.path } };
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const os = @import("os.zig");

test {
    _ = @import("unwind/cfi.zig");
    _ = @import("unwind/cfi_machine.zig");
    _ = @import("unwind/go_pclntab.zig");
    _ = @import("unwind/module.zig");
    _ = process_table;
    _ = registry_file;
    _ = @import("unwind/table.zig");
    _ = @import("unwind/table_set.zig");
}

fn marker() void {} // A function inside this very test binary.

const options_small_testing = Registry.Options{
    .rows_max = 1000,
    .modules_max = 4,
    .binaries_max = 4,
};

/// What `sync` computes, without the kernel maps.
fn entry_build_testing(
    registry: *Registry,
    entry: *ProcessEntry,
    regions: []const Region,
    vdso_image: ?*const VdsoImage,
) !Coverage {
    const prefix_buffer = try testing.allocator.alloc(u8, target.build_id_prefix_size);
    defer testing.allocator.free(prefix_buffer);
    return entry_build(.{
        .gpa = testing.allocator,
        .registry = registry,
        .prefix_buffer = prefix_buffer,
        .vdso_image = vdso_image,
        .pid = os.process.current_pid(),
    }, regions, entry);
}

test "this process: the registry finds the table row of one of our own functions" {
    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const regions = own.regions;

    var registry: Registry = undefined;
    try registry.init(testing.allocator, .{
        .rows_max = wire.rows_max,
        .modules_max = 16,
        .binaries_max = 64,
    });
    defer registry.deinit(testing.allocator);

    var entry: ProcessEntry = undefined;
    _ = try entry_build_testing(&registry, &entry, regions, null);
    try testing.expectEqual(@as(u32, @intCast(regions.len)), entry.count);
    try testing.expect(registry.set.modules_count > 0);

    const address = @intFromPtr(&marker);
    const mapping = process_table.find(&entry, address) orelse return error.TestUnexpectedResult;
    try testing.expect(mapping.module != wire.module_none);
    // The runtime address minus the mapping's bias is an address in the file's table.
    try testing.expect(registry.set.find(mapping.module, address -% mapping.bias) != null);

    // A second pass has nothing new to build, and gives the same entry.
    const modules_count = registry.set.modules_count;
    var again: ProcessEntry = undefined;
    _ = try entry_build_testing(&registry, &again, regions, null);
    try testing.expectEqual(modules_count, registry.set.modules_count);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&entry), std.mem.asBytes(&again));
}

test "this process: the vDSO gets a table, with a row for nearly every byte of its code" {
    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const regions = own.regions;

    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    // Only the vDSO's region: the other binaries are not this test's business.
    const region = for (regions) |*region| {
        if (std.mem.eql(u8, region.path, target.vdso_path)) break region;
    } else return error.TestUnexpectedResult;
    var entry: ProcessEntry = undefined;
    const image = own.vdso_image() orelse return error.SkipZigTest;
    const coverage = try entry_build_testing(&registry, &entry, region[0..1], image);
    try testing.expectEqual(@as(u32, 0), coverage.unavailable.get(.vdso_unknown));
    try testing.expectEqual(@as(u32, 1), registry.set.modules_count);

    const mapping = entry.mappings[0];
    try testing.expect(mapping.module != wire.module_none);

    // Every address of .text, as the kernel will see it, against the table.
    const shared_elf = @import("shared").elf;
    const text = (try shared_elf.find(image.bytes, ".text")) orelse
        return error.TestUnexpectedResult;
    var covered: u64 = 0;
    var address = region.start + text.vaddr;
    while (address < region.start + text.vaddr + text.size) : (address += 1) {
        if (registry.set.find(mapping.module, address -% mapping.bias) != null) covered += 1;
    }
    try testing.expect(covered * 10 >= text.size * 9);
}

test "a [vdso] of another size is not this agent's, and gets no table" {
    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const image = own.vdso_image() orelse return error.SkipZigTest;

    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    const regions = [_]Region{.{
        .start = 0x7000_0000,
        .end = 0x7000_0000 + image.bytes.len + 4096,
        .offset = 0,
        .inode = 0,
        .path = target.vdso_path,
        .build_id = null,
    }};
    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, &regions, image);
    try testing.expectEqual(@as(u32, 1), coverage.unavailable.get(.vdso_unknown));
    try testing.expectEqual(wire.module_none, entry.mappings[0].module);
}

test "a file that cannot be opened gives a mapping without a table, and is not remembered" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    const regions = [_]Region{.{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = "/nonexistent/file",
        .build_id = null,
    }};
    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, &regions, null);
    try testing.expectEqual(@as(u32, 1), entry.count);
    try testing.expectEqual(wire.module_none, entry.mappings[0].module);
    try testing.expectEqual(@as(u32, 1), coverage.unavailable.get(.unreadable));
    const identity = Identity{ .file = .{ .inode = 1, .path = "/nonexistent/file" } };
    try testing.expect(registry.lookup(identity) == null);
}

test "a file whose build ID is not the one the process mapped is refused, and not remembered" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    const build_id_wrong = [_]u8{ 1, 2, 3, 4 };
    const regions = [_]Region{.{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = "/usr/bin/ls",
        .build_id = &build_id_wrong,
    }};
    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, &regions, null);
    if (coverage.unavailable.get(.unreadable) == 1) return error.SkipZigTest; // No /usr/bin/ls.
    try testing.expectEqual(@as(u32, 1), coverage.unavailable.get(.wrong_file));
    try testing.expectEqual(wire.module_none, entry.mappings[0].module);
    try testing.expect(registry.lookup(.{ .build_id = &build_id_wrong }) == null);
    try testing.expectEqual(@as(u32, 0), registry.set.modules_count);
}
