//! Reads whole files into memory.
const std = @import("std");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn statx(dirfd: c_int, path: [*:0]const u8, flags: c_int, mask: c_uint, buf: *anyopaque) c_int;

const AT_EMPTY_PATH = 0x1000;
const STATX_INO = 0x100;

const O_RDONLY = 0;
const O_CLOEXEC = 0o2000000;

const EPERM = 1;
const ENOENT = 2;
const EINTR = 4;
const EACCES = 13;

pub const Error = error{ NotFound, PermissionDenied, ReadFailed, TooLarge } || std.mem.Allocator.Error;

fn errno() c_int {
    return std.c._errno().*;
}

pub const Read = struct {
    bytes: []u8,
    /// The inode of the file that was actually opened and read.
    inode: u64,
};

/// The inode of an open file, asked with statx. The layout of its buffer is fixed by the
/// kernel: 256 bytes, the first 4 say which fields were filled in, and the inode is a 64-bit
/// number at byte 32.
fn inodeOf(fd: c_int) ?u64 {
    var buf: [256]u8 = undefined;
    if (statx(fd, "", AT_EMPTY_PATH, STATX_INO, &buf) != 0) return null;
    const filled = std.mem.readInt(u32, buf[0..4], .little);
    if (filled & STATX_INO == 0) return null;
    return std.mem.readInt(u64, buf[32..40], .little);
}

/// Reads a whole file and says which inode it was. Fails with `TooLarge` instead of growing
/// past `max_bytes`. The caller frees `bytes`.
pub fn readAllInode(allocator: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) Error!Read {
    const fd = open(path.ptr, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return switch (errno()) {
        ENOENT => error.NotFound,
        EACCES, EPERM => error.PermissionDenied,
        else => error.ReadFailed,
    };
    defer _ = close(fd);

    // Asked of the open file, not of the path, so it is the file we read even if the path
    // is replaced at this moment.
    const inode = inodeOf(fd) orelse return error.ReadFailed;

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > max_bytes) return error.TooLarge;
        try list.appendSlice(allocator, chunk[0..len]);
    }
    return .{ .bytes = try list.toOwnedSlice(allocator), .inode = inode };
}

/// Reads a whole file. The caller frees the result.
pub fn readAll(allocator: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) Error![]u8 {
    const result = try readAllInode(allocator, path, max_bytes);
    return result.bytes;
}

test "readAll reads a file and enforces the size limit" {
    const text = try readAll(std.testing.allocator, "/proc/self/maps", 4 * 1024 * 1024);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len > 0);

    try std.testing.expectError(error.TooLarge, readAll(std.testing.allocator, "/proc/self/maps", 10));
    try std.testing.expectError(error.NotFound, readAll(std.testing.allocator, "/proc/does-not-exist", 100));
}

test "readAllInode says which file it read" {
    const a = try readAllInode(std.testing.allocator, "/proc/self/maps", 4 * 1024 * 1024);
    defer std.testing.allocator.free(a.bytes);
    const b = try readAllInode(std.testing.allocator, "/proc/self/maps", 4 * 1024 * 1024);
    defer std.testing.allocator.free(b.bytes);
    const c = try readAllInode(std.testing.allocator, "/proc/self/status", 4 * 1024 * 1024);
    defer std.testing.allocator.free(c.bytes);

    try std.testing.expect(a.inode != 0);
    try std.testing.expectEqual(a.inode, b.inode);
    try std.testing.expect(a.inode != c.inode);
}
