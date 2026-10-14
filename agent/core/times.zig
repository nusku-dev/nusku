const std = @import("std");
const CLOCK_MONOTONIC = @import("sys.zig").CLOCK_MONOTONIC;

extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern "c" fn timerfd_settime(fd: c_int, flags: c_int, new: *const Itimerspec, old: ?*Itimerspec) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

pub const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

const Itimerspec = extern struct {
    interval: Timespec,
    value: Timespec,
};

pub fn nowMs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    std.debug.assert(rc == 0); // CLOCK_MONOTONIC always exists on Linux
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn msToTimespec(ms: u32) Timespec {
    return .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000),
    };
}

pub fn sleepMs(ms: u64) void {
    const req = Timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&req, null); // waking early because of a signal is fine
}

pub fn ConfigTimer(interval_ms: u32, timer_fd: c_int) !void {
    const interval = msToTimespec(interval_ms);

    const armed = Itimerspec{
        .interval = interval,
        .value = interval,
    };
    if (timerfd_settime(timer_fd, 0, &armed, null) != 0) return error.Unexpected;
}
