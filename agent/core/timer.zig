const std = @import("std");
const CLOCK_MONOTONIC = @import("sys.zig").CLOCK_MONOTONIC;

extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern "c" fn timerfd_settime(fd: c_int, flags: c_int, new: *const Itimerspec, old: ?*Itimerspec) c_int;
extern "c" fn timerfd_create(clock: c_int, flags: c_int) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

const CLOCK_REALTIME = 0;
const TFD_NONBLOCK = 0o4000;
const TFD_CLOEXEC = 0o2000000;

pub const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

const Itimerspec = extern struct {
    interval: Timespec,
    value: Timespec,
};

fn clockNs(clock: c_int) u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(clock, &ts);
    std.debug.assert(rc == 0); // both clocks always exist on Linux
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Time since an arbitrary start that never goes backwards. For measuring how long things take.
pub fn monotonicNs() u64 {
    return clockNs(CLOCK_MONOTONIC);
}

/// Wall-clock time, nanoseconds since the Unix epoch. For timestamps other machines can read.
/// It can jump when somebody sets the clock, so never subtract two of them to get a duration.
pub fn realtimeNs() u64 {
    return clockNs(CLOCK_REALTIME);
}

pub fn nowMs() u64 {
    return monotonicNs() / 1_000_000;
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

pub fn configTimer(interval_ms: u32, timer_fd: c_int) !void {
    const interval = msToTimespec(interval_ms);

    const armed = Itimerspec{
        .interval = interval,
        .value = interval,
    };
    if (timerfd_settime(timer_fd, 0, &armed, null) != 0) return error.Unexpected;
}

pub fn createTimerfd() !c_int {
    const timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (timer_fd < 0) return error.Unexpected;
    return timer_fd;
}

test "both clocks advance, and the wall clock is a real date" {
    const mono = monotonicNs();
    const real = realtimeNs();
    sleepMs(20);
    try std.testing.expect(monotonicNs() - mono >= 15_000_000);
    try std.testing.expect(realtimeNs() - real >= 15_000_000);
    try std.testing.expect(real > 1_577_836_800 * 1_000_000_000); // after 1 January 2020
}
