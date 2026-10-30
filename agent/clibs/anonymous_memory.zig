const std = @import("std");

const page_align = std.heap.page_size_min;

/// Address space only: a page costs memory when it is written, and reads give zeros.
/// Anonymous memory, so unlike a mapped file it can never raise SIGBUS.
pub fn reserve(len: usize) error{OutOfMemory}![]align(page_align) u8 {
    const p = std.c.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
        -1,
        0,
    );
    if (p == std.c.MAP_FAILED) return error.OutOfMemory;
    const base: [*]align(page_align) u8 = @ptrCast(@alignCast(p));
    return base[0..len];
}

pub fn release(bytes: []align(page_align) u8) void {
    _ = std.c.munmap(@ptrCast(bytes.ptr), bytes.len);
}
