//! Address space that costs memory only where it is written.

const std = @import("std");
const assert = std.debug.assert;

const page_align = std.heap.page_size_min;

/// Address space only: a page costs memory when it is written, and reads give zeros.
/// Anonymous memory, so unlike a mapped file it can never raise SIGBUS.
pub fn reserve(size: usize) error{OutOfMemory}![]align(page_align) u8 {
    assert(size > 0);
    const pointer = std.c.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
        -1,
        0,
    );
    if (pointer == std.c.MAP_FAILED) return error.OutOfMemory;
    const base: [*]align(page_align) u8 = @ptrCast(@alignCast(pointer));
    return base[0..size];
}

pub fn release(bytes: []align(page_align) u8) void {
    assert(bytes.len > 0);
    const result = std.c.munmap(@ptrCast(bytes.ptr), bytes.len);
    // munmap fails only for a range that was never mapped: a bug in the caller.
    assert(result == 0);
}

test "reserved memory reads as zeros and can be written" {
    const bytes = try reserve(1 << 20);
    defer release(bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
    bytes[12345] = 7;
    try std.testing.expectEqual(@as(u8, 7), bytes[12345]);
}
