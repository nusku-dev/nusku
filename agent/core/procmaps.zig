//! What the backend needs to resolve a process's stack addresses: where each executable file
//! is loaded and which build it is. Read once per window, with build IDs cached.
const std = @import("std");
const sys = @import("sys.zig");
const maps = @import("maps.zig");
const buildid = @import("buildid.zig");
const timer = @import("timer.zig");

/// One executable region of the target process.
pub const Region = struct {
    start: u64,
    end: u64,
    /// The offset inside the file that `start` corresponds to.
    offset: u64,
    inode: u64,
    /// As the process sees it. Special regions have names like "[vdso]"; anonymous memory
    /// (for example JIT code) has an empty path.
    path: []const u8,
    /// Null when there is nothing to read (see buildid.forMapping).
    build_id: ?[]const u8,
};

pub const Location = struct {
    region: *const Region,
    /// Where the address is inside the region's file.
    file_offset: u64,
};

/// Which region a raw address falls into, and where in that region's file it is.
pub fn locate(regions: []const Region, address: u64) ?Location {
    for (regions) |*r| {
        if (address >= r.start and address < r.end) {
            return .{ .region = r, .file_offset = address - r.start + r.offset };
        }
    }
    return null;
}

pub const ProcessMaps = struct {
    allocator: std.mem.Allocator,
    pid: u32,
    /// Owns `table`.
    keep: std.heap.ArenaAllocator,
    /// The table from the last successful read. It is the cache of build IDs, and the answer
    /// when the process is gone.
    table: []const Region = &.{},
    /// How many build ID lookups touched the file system. Mostly for tests.
    lookups: usize = 0,

    pub fn init(allocator: std.mem.Allocator, pid: u32) ProcessMaps {
        std.debug.assert(sys.isValidPid(pid));
        return .{ .allocator = allocator, .pid = pid, .keep = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *ProcessMaps) void {
        self.keep.deinit();
        self.* = undefined;
    }

    /// The executable regions of the process right now. If the process is gone, the table from
    /// the last successful read (empty if there never was one). Everything returned lives in `out`.
    pub fn read(self: *ProcessMaps, out: std.mem.Allocator) ![]Region {
        var next = std.heap.ArenaAllocator.init(self.allocator);
        var moved = false;
        defer if (!moved) next.deinit();
        const arena = next.allocator();

        const parsed = maps.readExecutable(arena, self.pid) catch |err| switch (err) {
            error.NotFound => return cloneOf(out, self.table), // /proc/<pid> is gone
            else => return err,
        };
        // A live process always has executable mappings (at least the vDSO).
        // An empty file means a zombie: the process is dead but not collected yet.
        if (parsed.len == 0) return cloneOf(out, self.table);

        const regions = try arena.alloc(Region, parsed.len);
        for (parsed, regions, 0..) |m, *region, i| {
            region.* = .{
                .start = m.start,
                .end = m.end,
                .offset = m.offset,
                .inode = m.inode,
                .path = m.path,
                .build_id = try self.buildIdFor(arena, m, regions[0..i]),
            };
        }

        // Nothing below can fail: swap in the new table and free the old one.
        self.keep.deinit();
        self.keep = next;
        moved = true;
        self.table = regions;
        return cloneOf(out, regions);
    }

    /// The build ID for `m`: reused from this table or from the previous one if the same file
    /// is already known, otherwise read from the file system.
    fn buildIdFor(self: *ProcessMaps, arena: std.mem.Allocator, m: maps.Mapping, built: []const Region) !?[]const u8 {
        for (built) |r| {
            if (r.inode == m.inode and std.mem.eql(u8, r.path, m.path)) return r.build_id;
        }
        for (self.table) |r| {
            if (r.inode == m.inode and std.mem.eql(u8, r.path, m.path)) {
                // The previous table's memory is freed after the swap, so copy.
                return if (r.build_id) |id| try arena.dupe(u8, id) else null;
            }
        }
        self.lookups += 1;
        return buildid.forMapping(arena, self.pid, m);
    }
};

fn cloneOf(out: std.mem.Allocator, table: []const Region) ![]Region {
    const copy = try out.alloc(Region, table.len);
    for (table, copy) |src, *dst| {
        dst.* = src;
        dst.path = try out.dupe(u8, src.path);
        dst.build_id = if (src.build_id) |id| try out.dupe(u8, id) else null;
    }
    return copy;
}

test "locate finds the region and the offset inside its file" {
    const regions = [_]Region{
        .{ .start = 0x1000, .end = 0x3000, .offset = 0x500, .inode = 1, .path = "/bin/a", .build_id = null },
        .{ .start = 0x7000, .end = 0x8000, .offset = 0, .inode = 2, .path = "[vdso]", .build_id = null },
    };
    const hit = locate(&regions, 0x1234) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/bin/a", hit.region.path);
    try std.testing.expectEqual(@as(u64, 0x1234 - 0x1000 + 0x500), hit.file_offset);

    try std.testing.expect(locate(&regions, 0x3000) == null); // the end is exclusive
    try std.testing.expect(locate(&regions, 0xfff) == null);
    const vdso = locate(&regions, 0x7fff) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("[vdso]", vdso.region.path);
}

fn testMarker() void {} // a function whose address lies inside this very binary

test "this process: a raw address from our own code resolves to a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var pm = ProcessMaps.init(std.testing.allocator, sys.currentPid());
    defer pm.deinit();

    const regions = try pm.read(arena.allocator());
    const hit = locate(regions, @intFromPtr(&testMarker)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit.region.path.len > 0 and hit.region.path[0] == '/');
}

/// Right after fork the child still looks like us, and right after exec the dynamic loader
/// is still mapping libraries. Wait until it runs `name` (a part of the executable's path) and
/// its executable mappings have stopped changing.
pub fn waitForProgram(arena: std.mem.Allocator, pid: u32, name: []const u8) !void {
    var tries: usize = 0;
    var last_count: usize = 0;
    var stable: usize = 0;
    while (tries < 120) : (tries += 1) {
        var found = false;
        const mappings = try maps.readExecutable(arena, pid);
        for (mappings) |m| {
            if (std.mem.indexOf(u8, m.path, name) != null) found = true;
        }
        if (found and mappings.len == last_count) {
            stable += 1;
            if (stable >= 3) return; // same table on 3 reads in a row, 25 ms apart
        } else {
            stable = 0;
        }
        last_count = mappings.len;
        timer.sleepMs(25);
    }
    return error.ProgramDidNotStart;
}

fn waitForSleep(arena: std.mem.Allocator, pid: u32) !void {
    return waitForProgram(arena, pid, "/sleep");
}
test "another process: build IDs are read once and the table survives the process dying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const child = try sys.spawnSleeper();
    var reaped = false;
    defer if (!reaped) sys.reap(child);
    try waitForSleep(arena.allocator(), child);

    var pm = ProcessMaps.init(std.testing.allocator, child);
    defer pm.deinit();

    const first = try pm.read(arena.allocator());
    var sleep_region: ?Region = null;
    for (first) |r| {
        if (std.mem.endsWith(u8, r.path, "/sleep")) sleep_region = r;
    }
    const sleep = sleep_region orelse return error.TestUnexpectedResult;
    try std.testing.expect(sleep.build_id != null);
    std.debug.print("sleep: {s} build id {x}\n", .{ sleep.path, sleep.build_id.? });

    // A second read has nothing new to look up.
    const lookups = pm.lookups;
    try std.testing.expect(lookups > 0);
    const second = try pm.read(arena.allocator());
    try std.testing.expectEqual(lookups, pm.lookups);
    try std.testing.expectEqual(first.len, second.len);

    // The process dies: first it is a zombie (no mappings left), then it is gone.
    // Both times we get the last table back.

    sys.kill9(child);
    timer.sleepMs(100);
    try std.testing.expectEqual(first.len, (try pm.read(arena.allocator())).len);
    sys.reap(child);
    reaped = true;
    try std.testing.expectEqual(first.len, (try pm.read(arena.allocator())).len);
}
