const std = @import("std");

extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const SYS_pidfd_open = 434;

const EPERM = 1;
const ENOENT = 2;
const ESRCH = 3;
const EINTR = 4;
const EACCES = 13;
const ENOSYS = 38;

fn errno() c_int {
    return std.c._errno().*;
}

pub const PidFd = struct {
    fd: c_int,

    pub fn init(pid: u32) !PidFd {
        const rc = syscall(SYS_pidfd_open, @as(c_long, pid), @as(c_long, 0));
        if (rc < 0) return switch (errno()) {
            ESRCH => error.ProcessNotFound,
            EPERM => error.PermissionDenied,
            ENOSYS => error.NotSupported,
            else => error.Unexpected,
        };
        const pid_fd: c_int = @intCast(rc);

        return .{ .fd = pid_fd };
    }

    pub fn read_fd(self: PidFd, buf: *anyopaque, count: usize) !isize {
        const n = read(self.fd, buf, count);
        if (n < 0) return error.ReadFailed;
        return n;
    }

    pub fn deinit(self: *PidFd) void {
        _ = close(self.fd);
    }
};
