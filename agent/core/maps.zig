//! Parses /proc/<pid>/maps: where each file is loaded inside a process. The backend needs
//! this to turn a raw address from a stack into "offset N inside file F".
const std = @import("std");
const sys = @import("sys.zig");

pub const Error = error{BadMapsLine} || std.mem.Allocator.Error;

pub const Mapping = struct {
    start: u64,
    end: u64,

    /// The offset inside the file that `start` corresponds to.
    offset: u64,
    inode: u64,
    /// The path as the process sees it. Special mappings have names like "[vdso]".
    /// Empty for anonymous memory, for example JIT-compiled code.
    path: []const u8,
    /// The kernel appends " (deleted)" when the file was removed or replaced after it was mapped.
    deleted: bool,
};

/// The executable mappings in `text` (the contents of /proc/<pid>/maps), in file order.
/// Data mappings are skipped, since a stack address never points into them.
/// Everything returned lives in `arena`.
pub fn parseExecutable(arena: std.mem.Allocator, text: []const u8) Error![]Mapping {
    var list: std.ArrayList(Mapping) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (try parseLine(arena, line)) |mapping| try list.append(arena, mapping);
    }
    return list.items;
}

/// Reads and parses the executable mappings of a live process. Everything returned lives in `arena`.
pub fn readExecutable(arena: std.mem.Allocator, pid: u32) (Error || sys.ReadError)![]Mapping {
    std.debug.assert(sys.isValidPid(pid));
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/maps", .{pid}) catch unreachable;
    const text = try sys.readFile(arena, path, 4 * 1024 * 1024);
    return parseExecutable(arena, text);
}

/// One line looks like: "start-end perms offset dev inode      path"
fn parseLine(arena: std.mem.Allocator, line: []const u8) Error!?Mapping {
    var rest = line;

    const range = nextField(&rest) orelse return error.BadMapsLine;
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.BadMapsLine;
    const start = try parseNumber(range[0..dash], 16);
    const end = try parseNumber(range[dash + 1 ..], 16);

    const perms = nextField(&rest) orelse return error.BadMapsLine;
    if (perms.len != 4) return error.BadMapsLine;
    if (perms[2] != 'x') return null; // not executable

    const offset = try parseNumber(nextField(&rest) orelse return error.BadMapsLine, 16);
    _ = nextField(&rest) orelse return error.BadMapsLine; // the device, which we do not need
    const inode = try parseNumber(nextField(&rest) orelse return error.BadMapsLine, 10);

    // What is left is the path. It may contain spaces, and it may be missing.
    var path = skipSpaces(rest);
    const suffix = " (deleted)";
    const deleted = std.mem.endsWith(u8, path, suffix);
    if (deleted) path = path[0 .. path.len - suffix.len];

    return .{
        .start = start,
        .end = end,
        .offset = offset,
        .inode = inode,
        .path = try arena.dupe(u8, path),
        .deleted = deleted,
    };
}

/// Takes the next space-separated field off the front of `rest`.
fn nextField(rest: *[]const u8) ?[]const u8 {
    const text = skipSpaces(rest.*);
    var end: usize = 0;
    while (end < text.len and text[end] != ' ') end += 1;
    if (end == 0) return null;
    rest.* = text[end..];
    return text[0..end];
}

fn skipSpaces(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    return text[i..];
}

fn parseNumber(text: []const u8, base: u8) Error!u64 {
    return std.fmt.parseInt(u64, text, base) catch return error.BadMapsLine;
}

const sample =
    \\55d0a8c00000-55d0a8c21000 r--p 00000000 08:01 1310725                    /usr/bin/app
    \\55d0a8c21000-55d0a8d9e000 r-xp 00021000 08:01 1310725                    /usr/bin/app
    \\55d0a8d9e000-55d0a8e00000 rw-p 0019e000 08:01 1310725                    /usr/bin/app
    \\7f2c4a000000-7f2c4a021000 r-xp 00000000 08:01 2222                       /opt/my app/lib.so
    \\7f2c4a200000-7f2c4a201000 r-xp 00000000 08:01 3333                       /tmp/old-binary (deleted)
    \\7ffc2cfc9000-7ffc2cfcb000 r-xp 00000000 00:00 0                          [vdso]
    \\7ffc2cf00000-7ffc2cf21000 rw-p 00000000 00:00 0                          [stack]
    \\7f2c4b000000-7f2c4b010000 rwxp 00000000 00:00 0
;

test "keeps the executable mappings and skips the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const maps = try parseExecutable(arena.allocator(), sample);
    try std.testing.expectEqual(@as(usize, 5), maps.len);

    try std.testing.expectEqual(@as(u64, 0x55d0a8c21000), maps[0].start);
    try std.testing.expectEqual(@as(u64, 0x55d0a8d9e000), maps[0].end);
    try std.testing.expectEqual(@as(u64, 0x21000), maps[0].offset);
    try std.testing.expectEqual(@as(u64, 1310725), maps[0].inode);
    try std.testing.expectEqualStrings("/usr/bin/app", maps[0].path);
    try std.testing.expect(!maps[0].deleted);

    try std.testing.expectEqualStrings("/opt/my app/lib.so", maps[1].path); // a path with a space
    try std.testing.expectEqualStrings("/tmp/old-binary", maps[2].path);
    try std.testing.expect(maps[2].deleted);
    try std.testing.expectEqualStrings("[vdso]", maps[3].path);
    try std.testing.expectEqualStrings("", maps[4].path); // anonymous executable memory, like JIT code
}

test "rejects malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.BadMapsLine, parseExecutable(arena.allocator(), "garbage\n"));
    try std.testing.expectError(error.BadMapsLine, parseExecutable(arena.allocator(), "zz-yy r-xp 0 00:00 0 /x\n"));
    try std.testing.expectError(error.BadMapsLine, parseExecutable(arena.allocator(), "1000-2000 r-x 0 00:00 0 /x\n"));
}

fn testMarker() void {} // a function whose address lies inside this very binary

test "reads this process's own mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const maps = try readExecutable(arena.allocator(), sys.currentPid());
    try std.testing.expect(maps.len > 0);

    // Our own code must sit inside an executable mapping that is backed by a file.
    const here = @intFromPtr(&testMarker);
    var found = false;
    for (maps) |m| {
        if (here >= m.start and here < m.end) {
            found = true;
            try std.testing.expect(m.path.len > 0 and !m.deleted);
        }
    }
    try std.testing.expect(found);
}

test "a process that does not exist is NotFound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NotFound, readExecutable(arena.allocator(), std.math.maxInt(i32)));
}
