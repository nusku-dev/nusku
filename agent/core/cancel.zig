//! A handle that lets another thread stop a running `profile`.
const std = @import("std");

const EFD_CLOEXEC = 0o2000000;
const EFD_NONBLOCK = 0o4000;

extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
extern "c" fn write(fd: c_int, buf: *const anyopaque, count: usize) isize;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

pub const Cancel = struct {
    fd: c_int,

    pub fn init() error{Unexpected}!Cancel {
        const fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        if (fd < 0) return error.Unexpected;
        return .{ .fd = fd };
    }

    /// Closes the handle. Make sure the `profile` call that uses it has returned first.
    pub fn deinit(self: *Cancel) void {
        _ = close(self.fd);
        self.* = undefined;
    }

    /// Asks the profile that holds this handle to stop. Safe to call from any thread, from a
    /// signal handler (it is a single write), and more than once. It stays triggered for good.
    pub fn trigger(self: *const Cancel) void {
        const one: u64 = 1;
        _ = write(self.fd, &one, @sizeOf(u64)); // there is nothing useful to do if it fails
    }
};

fn triggerFromThread(cancel: *const Cancel) void {
    cancel.trigger();
}

test "trigger works, repeatedly and from another thread" {
    var cancel = try Cancel.init();
    defer cancel.deinit();

    cancel.trigger();
    const thread = try std.Thread.spawn(.{}, triggerFromThread, .{&cancel});
    thread.join();

    // An eventfd adds up the writes: two triggers read back as 2.
    var count: u64 = 0;
    try std.testing.expectEqual(@as(isize, 8), read(cancel.fd, &count, @sizeOf(u64)));
    try std.testing.expectEqual(@as(u64, 2), count);
}
