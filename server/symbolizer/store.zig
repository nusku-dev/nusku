//! Finds the file behind a region. For now only the local one: the file is opened the way
//! the target process sees the file system, so files that only exist inside a container work.
const std = @import("std");
const binary = @import("binary.zig");
const files = @import("files.zig");

/// How we know that the file we open is the file the agent saw.
pub const Identity = union(enum) {
    /// The GNU build ID the agent saw: a fingerprint of the content.
    build_id: []const u8,
    /// For files without one: the inode the agent saw. Weaker, because it says nothing about
    /// the content and means nothing outside this machine.
    inode: u64,
};

/// Opens the file at `region_path` as seen by process `pid`, and checks that it is the file
/// the agent saw. A different file (the package was upgraded while the process kept running
/// the old one) is an error, because its names would be wrong.
pub fn openLocal(
    allocator: std.mem.Allocator,
    pid: u32,
    region_path: []const u8,
    identity: Identity,
) !binary.Binary {
    // "[vdso]", "[heap]" and anonymous memory have no file to open.
    if (region_path.len == 0 or region_path[0] != '/') return error.NotAFile;

    // A path can be up to 4096 bytes; the prefix "/proc/4294967295/root" is 21 more.
    var path_buf: [4200]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/root{s}", .{ pid, region_path }) catch
        return error.PathTooLong;

    const read = try files.readAllInode(allocator, path, binary.max_binary_bytes);
    switch (identity) {
        .inode => |inode| if (read.inode != inode) {
            allocator.free(read.bytes);
            return error.InodeMismatch;
        },
        .build_id => {},
    }

    var bin = try binary.Binary.load(allocator, read.bytes);
    errdefer bin.deinit(allocator);
    switch (identity) {
        .build_id => |id| if (!bin.matches(id)) return error.BuildIdMismatch,
        .inode => {},
    }
    return bin;
}

test "only real files can be opened" {
    try std.testing.expectError(error.NotAFile, openLocal(std.testing.allocator, 1, "[vdso]", .{ .build_id = "id" }));
    try std.testing.expectError(error.NotAFile, openLocal(std.testing.allocator, 1, "", .{ .inode = 5 }));
}

test "a missing file is NotFound" {
    const me: u32 = @intCast(std.c.getpid());
    try std.testing.expectError(error.NotFound, openLocal(std.testing.allocator, me, "/does/not/exist", .{ .build_id = "id" }));
    try std.testing.expectError(error.NotFound, openLocal(std.testing.allocator, me, "/does/not/exist", .{ .inode = 5 }));
}
