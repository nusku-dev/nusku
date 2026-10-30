//! Waits on the descriptors that drive a profile run, all at once.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Source = enum {
    /// Time to report a window.
    report_timer,
    /// Time to drain the kernel buffers, between reports.
    tick_timer,
    /// The target process exited.
    target_exit,
    /// Another thread asked the run to stop.
    cancel,
};

pub const Ready = std.EnumSet(Source);

pub const Poll = struct {
    fds: [source_count]linux.pollfd,

    const source_count = @typeInfo(Source).@"enum".fields.len;

    /// A descriptor of -1 is never ready: poll(2) skips negative descriptors.
    pub fn init(fds: std.EnumArray(Source, i32)) Poll {
        var poll: Poll = undefined;
        for (&poll.fds, 0..) |*pollfd, index| {
            const source: Source = @enumFromInt(index);
            pollfd.* = .{ .fd = fds.get(source), .events = linux.POLL.IN, .revents = 0 };
        }
        // The timers and the target are always there; only cancel is optional.
        assert(poll.fds[@intFromEnum(Source.report_timer)].fd >= 0);
        assert(poll.fds[@intFromEnum(Source.tick_timer)].fd >= 0);
        assert(poll.fds[@intFromEnum(Source.target_exit)].fd >= 0);
        return poll;
    }

    /// Waits until a source is ready, or `timeout_ms` passed (-1 waits for ever). A signal ends
    /// the wait early with nothing ready, which the caller treats like a timeout.
    pub fn wait(poll: *Poll, timeout_ms: i32) error{Unexpected}!Ready {
        assert(timeout_ms >= -1);
        const result = linux.poll(&poll.fds, poll.fds.len, timeout_ms);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => return .initEmpty(),
            else => return error.Unexpected,
        }
        assert(result <= poll.fds.len);

        var ready: Ready = .initEmpty();
        for (poll.fds, 0..) |pollfd, index| {
            const source: Source = @enumFromInt(index);
            if (source == .target_exit) {
                // An exited process's pidfd reports POLLIN, and POLLHUP on newer kernels.
                if (pollfd.revents != 0) ready.insert(source);
            } else {
                if (pollfd.revents & linux.POLL.IN != 0) ready.insert(source);
            }
        }
        return ready;
    }
};
