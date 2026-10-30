//! A handle that lets another thread, or a signal handler, stop a running `profile`.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Cancel = struct {
    /// An eventfd: readable once triggered, and it stays readable.
    fd: i32,

    pub fn init() error{Unexpected}!Cancel {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.Unexpected;
        return .{ .fd = @intCast(result) };
    }

    /// Closes the handle. The `profile` call that uses it must have returned first.
    pub fn deinit(cancel: *Cancel) void {
        assert(cancel.fd >= 0);
        _ = linux.close(cancel.fd);
        cancel.* = undefined;
    }

    /// Asks the `profile` that holds this handle to stop. Safe from any thread, from a signal
    /// handler (it is one write), and more than once. It stays triggered for good.
    pub fn trigger(cancel: *const Cancel) void {
        assert(cancel.fd >= 0);
        const one: u64 = 1;
        // It can only fail if the counter would overflow, after 2^64 - 1 triggers: it is
        // triggered then anyway, so there is nothing to handle.
        _ = linux.write(cancel.fd, std.mem.asBytes(&one), @sizeOf(u64));
    }
};

fn trigger_from_thread(cancel: *const Cancel) void {
    cancel.trigger();
}

test "trigger works, repeatedly and from another thread" {
    var cancel = try Cancel.init();
    defer cancel.deinit();

    cancel.trigger();
    const thread = try std.Thread.spawn(.{}, trigger_from_thread, .{&cancel});
    thread.join();

    // An eventfd adds up its writes: two triggers read back as 2.
    var count: u64 = 0;
    const result = linux.read(cancel.fd, std.mem.asBytes(&count), @sizeOf(u64));
    try std.testing.expectEqual(@as(usize, 8), result);
    try std.testing.expectEqual(@as(u64, 2), count);
}
