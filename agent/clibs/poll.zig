const std = @import("std");
const Cancel = @import("cancel.zig").Cancel;

extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;

const POLLIN: c_short = 1;
const EINTR = 4;

fn errno() c_int {
    return std.c._errno().*;
}

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

pub const Events = struct {
    timer: bool = false,
    exited: bool = false,
    cancelled: bool = false,
};

pub const Poll = struct {
    fds: [3]PollFd,

    pub fn init(
        timer_fd: c_int,
        pid_fd: c_int,
        cancel: ?*const Cancel,
    ) Poll {
        return .{ .fds = [3]PollFd{
            .{ .fd = timer_fd, .events = POLLIN, .revents = 0 },
            .{ .fd = pid_fd, .events = POLLIN, .revents = 0 },
            .{ .fd = if (cancel) |c| c.fd else -1, .events = POLLIN, .revents = 0 },
        } };
    }

    pub fn wait(self: *Poll, timeout_ms: c_int) !Events {
        try pollSafe(&self.fds, timeout_ms);

        return .{
            .timer = self.fds[0].revents & POLLIN != 0,
            .exited = self.fds[1].revents != 0,
            .cancelled = self.fds[2].revents & POLLIN != 0,
        };
    }

    fn pollSafe(fds: []PollFd, timeout_ms: c_int) !void {
        const result = poll(fds.ptr, fds.len, timeout_ms);
        if (result >= 0) return;
        if (errno() == EINTR) return error.Interrupted;
        return error.PollFailed;
    }
};
