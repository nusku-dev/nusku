//! Joins what the agent knows about a process (its executable regions) with the unwind
//! registry: loads the table of every binary not seen before and returns the process's entry
//! for the BPF map, plus how many mappings have no table, and why.
const std = @import("std");
const unwind = @import("unwind");
const procmaps = @import("procmaps.zig");
const buildid = @import("buildid.zig");
const elfload = @import("elfload.zig");
const sys = @import("sys.zig");

const Registry = unwind.registry.Registry;
const Outcome = unwind.registry.Outcome;
const Identity = unwind.registry.Identity;
pub const Cause = unwind.registry.Cause;
pub const ProcessEntry = unwind.procmap.ProcessEntry;

pub const Built = struct {
    entry: ProcessEntry,
    /// How many mappings of this process have no table, by reason.
    unavailable: std.EnumArray(Cause, u32),
};

fn identityOf(r: procmaps.Region) Identity {
    if (r.build_id) |id| return .{ .build_id = id };
    return .{ .file = .{ .inode = r.inode, .path = r.path } };
}

/// Modules the registry holds after this call that it did not hold before are
/// `registry.set.modules.items[before..]`, where `before` is the length at the call.
pub fn build(
    allocator: std.mem.Allocator,
    registry: *Registry,
    pid: u32,
    regions: []const procmaps.Region,
) !Built {
    var inputs: std.ArrayList(unwind.procmap.Input) = .empty;
    defer inputs.deinit(allocator);
    var unavailable = std.EnumArray(Cause, u32).initFill(0);

    for (regions) |r| {
        const outcome = try outcomeFor(registry, pid, r);
        switch (outcome) {
            .unavailable => |cause| unavailable.getPtr(cause).* += 1,
            .loaded => {},
        }
        try inputs.append(allocator, .{ .start = r.start, .end = r.end, .offset = r.offset, .outcome = outcome });
    }
    return .{ .entry = try unwind.procmap.build(inputs.items), .unavailable = unavailable };
}

fn outcomeFor(registry: *Registry, pid: u32, r: procmaps.Region) !Outcome {
    const identity = identityOf(r);
    if (try registry.lookup(identity)) |known| return known;

    // [vdso] and anonymous code have no file to read.
    if (r.path.len == 0 or r.path[0] != '/') return .{ .unavailable = .unreadable };

    // The file as the process sees it, so files that exist only inside a container work too.
    var path_buf: [4200]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/root{s}", .{ pid, r.path }) catch
        return .{ .unavailable = .unreadable };
    var file = sys.File.openRead(path) catch return .{ .unavailable = .unreadable };
    defer file.deinit();

    // The path may lead to a different file than the one the process mapped.
    if (r.build_id) |want| {
        var prefix: [64 * 1024]u8 = undefined;
        const n = file.readAt(&prefix, 0) catch return .{ .unavailable = .unreadable };
        const got = buildid.fromPrefix(prefix[0..n]) orelse return .{ .unavailable = .wrong_file };
        if (!std.mem.eql(u8, got, want)) return .{ .unavailable = .wrong_file };
    }

    var loaded = elfload.load(file) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .unavailable = .unreadable },
    };
    defer loaded.deinit();
    return try registry.add(identity, loaded.bytes, r.start, r.end, r.offset);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn marker() void {} // a function inside this very test binary

test "this process: the registry finds the table row of one of our own functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pm = procmaps.ProcessMaps.init(testing.allocator, sys.currentPid());
    defer pm.deinit();
    const regions = try pm.read(arena.allocator());

    var reg = Registry.init(testing.allocator, 262_144, 16);
    defer reg.deinit();

    const before = reg.set.modules.items.len;
    const built = try build(testing.allocator, &reg, sys.currentPid(), regions);
    try testing.expectEqual(@as(u32, @intCast(regions.len)), built.entry.count);
    try testing.expect(reg.set.modules.items.len > before);

    const address = @intFromPtr(&marker);
    const mapping = unwind.procmap.find(&built.entry, address) orelse return error.TestUnexpectedResult;
    try testing.expect(mapping.module != unwind.procmap.no_module);
    // The address in memory, minus the mapping's bias, is an address in the file's table.
    const row = reg.set.find(mapping.module, address -% mapping.bias);
    try testing.expect(row != null);
    std.debug.print("tables: {d} mappings, {d} modules, {d} rows, vdso/anonymous without table: {d}\n", .{
        built.entry.count, reg.set.modules.items.len, reg.set.rows.items.len, built.unavailable.get(.unreadable),
    });

    // A second pass has nothing new to load, and gives the same entry.
    const modules_after = reg.set.modules.items.len;
    const again = try build(testing.allocator, &reg, sys.currentPid(), regions);
    try testing.expectEqual(modules_after, reg.set.modules.items.len);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&built.entry), std.mem.asBytes(&again.entry));
}

test "a file that cannot be opened gives a mapping without a table, and is not remembered" {
    var reg = Registry.init(testing.allocator, 1000, 4);
    defer reg.deinit();
    const regions = [_]procmaps.Region{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0, .inode = 1, .path = "/nonexistent/file", .build_id = null },
    };
    const built = try build(testing.allocator, &reg, sys.currentPid(), &regions);
    try testing.expectEqual(@as(u32, 1), built.entry.count);
    try testing.expectEqual(unwind.procmap.no_module, built.entry.mappings[0].module);
    try testing.expectEqual(@as(u32, 1), built.unavailable.get(.unreadable));
    try testing.expect((try reg.lookup(.{ .file = .{ .inode = 1, .path = "/nonexistent/file" } })) == null);
}

test "a file whose build ID is not the one the process mapped is refused, and not remembered" {
    var reg = Registry.init(testing.allocator, 1000, 4);
    defer reg.deinit();
    const wrong = [_]u8{ 1, 2, 3, 4 };
    const regions = [_]procmaps.Region{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0, .inode = 1, .path = "/usr/bin/ls", .build_id = &wrong },
    };
    const built = try build(testing.allocator, &reg, sys.currentPid(), &regions);
    if (built.unavailable.get(.unreadable) == 1) return error.SkipZigTest; // no /usr/bin/ls here
    try testing.expectEqual(@as(u32, 1), built.unavailable.get(.wrong_file));
    try testing.expectEqual(unwind.procmap.no_module, built.entry.mappings[0].module);
    try testing.expect((try reg.lookup(.{ .build_id = &wrong })) == null);
    try testing.expectEqual(@as(usize, 0), reg.set.modules.items.len);
}
