//! A handle that lets another thread.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Cancel = struct {
    fd: i32,

    pub fn init() error{Unexpected}!Cancel {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.Unexpected;
        return .{ .fd = @intCast(result) };
    }

    pub fn deinit(cancel: *Cancel) void {
        assert(cancel.fd >= 0);
        _ = linux.close(cancel.fd);
        cancel.* = undefined;
    }

    /// Safe from any thread, from a signal handler (it is one write), and more than once.
    pub fn trigger(cancel: *const Cancel) void {
        assert(cancel.fd >= 0);
        const one: u64 = 1;
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

    var count: u64 = 0;
    const result = linux.read(cancel.fd, std.mem.asBytes(&count), @sizeOf(u64));
    try std.testing.expectEqual(@as(usize, 8), result);
    try std.testing.expectEqual(@as(u64, 2), count);
}
