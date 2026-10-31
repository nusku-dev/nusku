//! The unwind tables of every binary the target maps, mirrored into the kernel's maps.
//!
//! This is the one owner of the three unwind maps. Every program that walks user stacks (the
//! CPU sampler today, others later) binds them by name, so the tables are built and written once
//! however many programs read them.
//!
//! `sync` runs at every report, so it is written for the case where nothing changed: a lookup
//! per region that allocates nothing, and no system call unless something did change. When it
//! did, it writes in dependency order, rows, then module descriptors, then the process entry,
//! so the kernel never follows a reference to something that is not there yet.

const std = @import("std");
const assert = std.debug.assert;
const map_file = @import("../bpf/map.zig");
const loader = @import("../bpf/loader.zig");
const libbpf = @import("../bpf/libbpf.zig");
const unwind_wire = @import("../bpf/kernel/shared/unwind_wire.zig");
const File = @import("../os/file.zig").File;
const build_id = @import("../target/build_id.zig");
const Region = @import("../target/regions.zig").Region;
const vdso = @import("../target/vdso.zig");
const elf_file = @import("elf_file.zig");
const process_table = @import("process_table.zig");
const registry_file = @import("registry.zig");

const Map = map_file.Map;
const Registry = registry_file.Registry;
const Outcome = registry_file.Outcome;
const Identity = registry_file.Identity;
const Cause = registry_file.Cause;
const ProcessEntry = unwind_wire.ProcessEntry;
const Module = unwind_wire.Module;

const log = @import("../log.zig").agent;

/// Every binary remembered, with a table or without. Four times the modules, because many
/// mapped files (the vDSO, data-only libraries) never get one.
const binaries_max = 4 * unwind_wire.modules_max;
/// How much of a file is read to check its build ID (see target/build_id.zig).
const build_id_prefix_size = build_id.prefix_size;

pub const MapName = enum { unwind_rows, unwind_modules, unwind_procs };

/// How well the target's code can be unwound, as of the last sync.
pub const Coverage = struct {
    /// Executable mappings in the kernel's entry for the target.
    mappings: u32 = 0,
    /// Executable mappings that did not fit in the entry: frames in them cannot be unwound.
    mappings_dropped: u32 = 0,
    /// Mappings without a table, by reason. Their frames fall back to frame pointers.
    unavailable: std.EnumArray(Cause, u32) = .initFill(0),
};

pub const Tables = struct {
    registry: Registry,
    maps: std.EnumArray(MapName, Map),
    /// The entry the kernel has for the target, so an unchanged one is not written again.
    entry_written: ProcessEntry,
    /// The entry being built by `sync`. A field rather than a local: it is 4 KiB.
    entry_next: ProcessEntry,
    /// Modules `[0, modules_written)` are in the kernel.
    modules_written: u32,
    /// Where `sync` reads the start of a file to check its build ID.
    prefix_buffer: []u8,
    /// The agent's own vDSO, the source of every target's [vdso] table. Null without one.
    vdso_image: ?vdso.Image,
    coverage: Coverage,

    pub fn init(tables: *Tables, gpa: std.mem.Allocator) !void {
        tables.* = .{
            .registry = undefined,
            .maps = undefined,
            .entry_written = std.mem.zeroes(ProcessEntry),
            .entry_next = undefined,
            .modules_written = 0,
            .prefix_buffer = &.{},
            .vdso_image = null,
            .coverage = .{},
        };

        try tables.registry.init(gpa, .{
            .rows_max = unwind_wire.rows_max,
            .modules_max = unwind_wire.modules_max,
            .binaries_max = binaries_max,
        });
        errdefer tables.registry.deinit(gpa);

        tables.prefix_buffer = try gpa.alloc(u8, build_id_prefix_size);
        errdefer gpa.free(tables.prefix_buffer);

        tables.vdso_image = try vdso.read(gpa);
        errdefer if (tables.vdso_image) |*image| image.deinit(gpa);
        if (tables.vdso_image == null) {
            log.warn("no vDSO image: samples inside it will lose their callers", .{});
        }

        try maps_create(&tables.maps);
        // The row value is written straight from the set: it has exactly the map's size.
        assert(tables.registry.set.rows.len == unwind_wire.rows_max);
    }

    pub fn deinit(tables: *Tables, gpa: std.mem.Allocator) void {
        for (&tables.maps.values) |*map| map.deinit();
        if (tables.vdso_image) |*image| image.deinit(gpa);
        gpa.free(tables.prefix_buffer);
        tables.registry.deinit(gpa);
        tables.* = undefined;
    }

    /// The maps, by the names the kernel programs declare them under.
    pub fn bindings(tables: *const Tables) [3]loader.MapBinding {
        var result: [3]loader.MapBinding = undefined;
        for (&result, 0..) |*binding, index| {
            const name: MapName = @enumFromInt(index);
            binding.* = .{ .name = @tagName(name), .fd = tables.maps.get(name).fd };
        }
        return result;
    }

    /// Builds the tables of binaries `regions` maps for the first time, and rewrites the
    /// target's entry when it changed.
    pub fn sync(tables: *Tables, gpa: std.mem.Allocator, pid: u32, regions: []const Region) !void {
        assert(pid > 0);
        const coverage = try entry_build(.{
            .gpa = gpa,
            .registry = &tables.registry,
            .prefix_buffer = tables.prefix_buffer,
            .vdso_image = if (tables.vdso_image) |*image| image else null,
            .pid = pid,
        }, regions, &tables.entry_next);

        try tables.modules_write();
        const entry_changed = !std.mem.eql(
            u8,
            std.mem.asBytes(&tables.entry_next),
            std.mem.asBytes(&tables.entry_written),
        );
        if (entry_changed) try tables.process_write(pid);
        if (!std.meta.eql(coverage, tables.coverage)) coverage_log(&coverage);
        tables.coverage = coverage;
    }

    /// Writes the modules the kernel does not have yet: first the rows, then the descriptors,
    /// so a descriptor never points at rows that are not there.
    fn modules_write(tables: *Tables) !void {
        const set = &tables.registry.set;
        assert(tables.modules_written <= set.modules_count);
        if (tables.modules_written == set.modules_count) return; // Nothing new: the usual case.

        // One value holds every row, so it is written whole. The rows the kernel already has
        // are the same bytes, so a program reading them during the write sees no change.
        const rows = tables.maps.getPtr(.unwind_rows);
        const key: u32 = 0;
        try rows.update(std.mem.asBytes(&key), std.mem.sliceAsBytes(set.rows));

        const modules_map = tables.maps.getPtrConst(.unwind_modules);
        const modules = try map_file.TypedMap(u32, Module).init(modules_map);
        var module_id = tables.modules_written;
        while (module_id < set.modules_count) : (module_id += 1) {
            try modules.update(module_id, &set.modules[module_id]);
        }
        log.debug("unwind tables written to the kernel", .{
            .modules_first = tables.modules_written,
            .modules_count = set.modules_count,
            .rows_used = set.rows_count,
        });
        tables.modules_written = set.modules_count;
    }

    /// Call after the modules the entry refers to are written.
    fn process_write(tables: *Tables, pid: u32) !void {
        // Pair assertion with modules_write: every module the entry names is in the kernel.
        for (tables.entry_next.mappings[0..tables.entry_next.count]) |mapping| {
            if (mapping.module != unwind_wire.module_none) {
                assert(mapping.module < tables.modules_written);
            }
        }
        const processes_map = tables.maps.getPtrConst(.unwind_procs);
        const processes = try map_file.TypedMap(u32, ProcessEntry).init(processes_map);
        try processes.update(pid, &tables.entry_next);
        tables.entry_written = tables.entry_next;
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
            .mappings_max = unwind_wire.mappings_max,
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
    vdso_image: ?*const vdso.Image,
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
    if (std.mem.eql(u8, region.path, vdso.path)) return outcome_for_vdso(context, region);
    // Anonymous code (JIT) and the other special mappings have no file to read.
    if (region.path.len == 0) return .{ .unavailable = .unreadable };
    if (region.path[0] != '/') return .{ .unavailable = .unreadable };

    const identity = identity_of(region);
    if (context.registry.lookup(identity)) |known| return known;

    // The file as the process sees it, so files that exist only inside a container work.
    var path_buffer: [4200]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/root{s}", .{
        context.pid,
        region.path,
    }) catch return .{ .unavailable = .unreadable };
    var file = File.open(path) catch return .{ .unavailable = .unreadable };
    defer file.deinit();

    // The path may lead to another file than the one the process mapped (an upgrade replaced
    // it). Not remembered: the next report checks again.
    if (region.build_id) |build_id_expected| {
        const read = file.read_at(context.prefix_buffer, 0) catch
            return .{ .unavailable = .unreadable };
        const build_id_found = build_id.from_prefix(context.prefix_buffer[0..read]) orelse
            return .{ .unavailable = .wrong_file };
        if (!std.mem.eql(u8, build_id_found, build_id_expected)) {
            return .{ .unavailable = .wrong_file };
        }
    }

    var loaded = elf_file.load(&file) catch |err| switch (err) {
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
    assert(std.mem.eql(u8, region.path, vdso.path));
    const image = context.vdso_image orelse return .{ .unavailable = .vdso_unknown };
    if (!image.matches(region.end - region.start)) return .{ .unavailable = .vdso_unknown };

    // The vDSO has no inode: without a build ID, its path names it.
    const identity: Identity = if (image.build_id) |id|
        .{ .build_id = id }
    else
        .{ .file = .{ .inode = 0, .path = vdso.path } };
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

/// The maps as the kernel programs declare them. loader.map_check holds each program to these.
fn maps_create(maps: *std.EnumArray(MapName, Map)) libbpf.Error!void {
    const c = libbpf.c;
    const specs = std.EnumArray(MapName, map_file.Spec).init(.{
        .unwind_rows = .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = unwind_wire.rows_max * @sizeOf(unwind_wire.Row),
            .max_entries = 1,
        },
        .unwind_modules = .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(Module),
            .max_entries = unwind_wire.modules_max,
        },
        .unwind_procs = .{
            .map_type = c.BPF_MAP_TYPE_HASH,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(ProcessEntry),
            .max_entries = unwind_wire.processes_max,
        },
    });

    var created: u32 = 0;
    errdefer for (maps.values[0..created]) |*map| map.deinit();
    for (&maps.values, 0..) |*map, index| {
        const name: MapName = @enumFromInt(index);
        map.* = try Map.create(@tagName(name), specs.get(name));
        created += 1;
    }
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const process_maps = @import("../target/process_maps.zig");
const regions_file = @import("../target/regions.zig");
const process = @import("../os/process.zig");

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
    vdso_image: ?*const vdso.Image,
) !Coverage {
    const prefix_buffer = try testing.allocator.alloc(u8, build_id_prefix_size);
    defer testing.allocator.free(prefix_buffer);
    return entry_build(.{
        .gpa = testing.allocator,
        .registry = registry,
        .prefix_buffer = prefix_buffer,
        .vdso_image = vdso_image,
        .pid = process.current_pid(),
    }, regions, entry);
}

test "this process: the registry finds the table row of one of our own functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();
    const mappings = try process_maps.read(arena.allocator(), pid);
    const regions = try regions_file.build(arena.allocator(), mappings, pid, &.{});

    var registry: Registry = undefined;
    try registry.init(testing.allocator, .{
        .rows_max = unwind_wire.rows_max,
        .modules_max = 16,
        .binaries_max = 64,
    });
    defer registry.deinit(testing.allocator);

    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, regions, null);
    try testing.expectEqual(@as(u32, @intCast(regions.len)), entry.count);
    try testing.expect(registry.set.modules_count > 0);

    const address = @intFromPtr(&marker);
    const mapping = process_table.find(&entry, address) orelse return error.TestUnexpectedResult;
    try testing.expect(mapping.module != unwind_wire.module_none);
    // The runtime address minus the mapping's bias is an address in the file's table.
    try testing.expect(registry.set.find(mapping.module, address -% mapping.bias) != null);
    std.debug.print("tables: {d} mappings, {d} modules, {d} rows, without a table: {d}\n", .{
        entry.count,
        registry.set.modules_count,
        registry.set.rows_count,
        coverage.unavailable.get(.unreadable),
    });

    // A second pass has nothing new to build, and gives the same entry.
    const modules_count = registry.set.modules_count;
    var again: ProcessEntry = undefined;
    _ = try entry_build_testing(&registry, &again, regions, null);
    try testing.expectEqual(modules_count, registry.set.modules_count);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&entry), std.mem.asBytes(&again));
}

test "this process: the vDSO gets a table, with a row for nearly every byte of its code" {
    var image = (try vdso.read(testing.allocator)) orelse return error.SkipZigTest;
    defer image.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();
    const mappings = try process_maps.read(arena.allocator(), pid);
    const regions = try regions_file.build(arena.allocator(), mappings, pid, &.{});

    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    // Only the vDSO's region: the other binaries are not this test's business.
    const region = for (regions) |*region| {
        if (std.mem.eql(u8, region.path, vdso.path)) break region;
    } else return error.TestUnexpectedResult;
    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, region[0..1], &image);
    try testing.expectEqual(@as(u32, 0), coverage.unavailable.get(.vdso_unknown));
    try testing.expectEqual(@as(u32, 1), registry.set.modules_count);

    const mapping = entry.mappings[0];
    try testing.expect(mapping.module != unwind_wire.module_none);

    // Every address of .text, as the kernel will see it, against the table.
    const elf_sections = @import("elf_sections.zig");
    const text = (try elf_sections.find(image.bytes, ".text")) orelse
        return error.TestUnexpectedResult;
    var covered: u64 = 0;
    var address = region.start + text.vaddr;
    while (address < region.start + text.vaddr + text.size) : (address += 1) {
        if (registry.set.find(mapping.module, address -% mapping.bias) != null) covered += 1;
    }
    std.debug.print("vdso: {d} of {d} bytes of .text have a row\n", .{ covered, text.size });
    try testing.expect(covered * 10 >= text.size * 9);
}

test "a [vdso] of another size is not this agent's, and gets no table" {
    var image = (try vdso.read(testing.allocator)) orelse return error.SkipZigTest;
    defer image.deinit(testing.allocator);

    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_small_testing);
    defer registry.deinit(testing.allocator);

    const regions = [_]Region{.{
        .start = 0x7000_0000,
        .end = 0x7000_0000 + image.bytes.len + 4096,
        .offset = 0,
        .inode = 0,
        .path = vdso.path,
        .build_id = null,
    }};
    var entry: ProcessEntry = undefined;
    const coverage = try entry_build_testing(&registry, &entry, &regions, &image);
    try testing.expectEqual(@as(u32, 1), coverage.unavailable.get(.vdso_unknown));
    try testing.expectEqual(unwind_wire.module_none, entry.mappings[0].module);
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
    try testing.expectEqual(unwind_wire.module_none, entry.mappings[0].module);
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
    try testing.expectEqual(unwind_wire.module_none, entry.mappings[0].module);
    try testing.expect(registry.lookup(.{ .build_id = &build_id_wrong }) == null);
    try testing.expectEqual(@as(u32, 0), registry.set.modules_count);
}

test "sync writes the tables into the kernel, and nothing when nothing changed (needs root)" {
    var tables: Tables = undefined;
    tables.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    defer tables.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();
    const mappings = try process_maps.read(arena.allocator(), pid);
    const regions = try regions_file.build(arena.allocator(), mappings, pid, &.{});

    try tables.sync(testing.allocator, pid, regions);
    try testing.expect(tables.modules_written > 0);
    try testing.expectEqual(tables.registry.set.modules_count, tables.modules_written);
    try testing.expectEqual(@as(u32, @intCast(regions.len)), tables.coverage.mappings);

    const processes_map = tables.maps.getPtrConst(.unwind_procs);
    const processes = try map_file.TypedMap(u32, ProcessEntry).init(processes_map);
    var entry_kernel: ProcessEntry = undefined;
    try testing.expect(try processes.lookup(pid, &entry_kernel));
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&tables.entry_written),
        std.mem.asBytes(&entry_kernel),
    );

    const modules_written = tables.modules_written;
    try tables.sync(testing.allocator, pid, regions);
    try testing.expectEqual(modules_written, tables.modules_written);
}
