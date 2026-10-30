//! A process file descriptor: it becomes readable when the process exits, so the agent can wait
//! on the target's exit together with its timers, and a reused pid can never be mistaken for it.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const PidFd = struct {
    fd: i32,

    pub const Error = error{ ProcessNotFound, PermissionDenied, NotSupported, Unexpected };

    pub fn init(pid: u32) Error!PidFd {
        assert(pid > 0);
        assert(pid <= std.math.maxInt(i32));

        const result = linux.pidfd_open(@intCast(pid), 0);
        return switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            .SRCH => error.ProcessNotFound,
            .PERM => error.PermissionDenied,
            .NOSYS => error.NotSupported, // Linux older than 5.3.
            else => error.Unexpected,
        };
    }

    pub fn deinit(pidfd: *PidFd) void {
        assert(pidfd.fd >= 0);
        _ = linux.close(pidfd.fd);
        pidfd.* = undefined;
    }
};

test "this process has a pidfd, and a pid that cannot exist has none" {
    var pidfd = try PidFd.init(@intCast(linux.getpid()));
    defer pidfd.deinit();
    try std.testing.expect(pidfd.fd >= 0);

    try std.testing.expectError(error.ProcessNotFound, PidFd.init(std.math.maxInt(i32)));
}
