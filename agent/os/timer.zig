//! Clocks, and a timer the agent waits on to run at its own pace.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const ns_per_ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;

/// Time since an arbitrary start, which never goes backwards. For measuring durations.
pub fn monotonic_ns() u64 {
    return clock_ns(.MONOTONIC);
}

/// Time since boot, counting the time the machine was suspended: the clock /proc's start
/// times are counted on.
pub fn boottime_ns() u64 {
    return clock_ns(.BOOTTIME);
}

/// When a run of `duration_s` seconds that starts now ends; null for a run without an end.
pub fn deadline_from(duration_s: u32) ?u64 {
    if (duration_s == 0) return null;
    return monotonic_ns() + @as(u64, duration_s) * ns_per_s;
}

/// How long poll may wait: until the deadline, so it wakes for it even if nothing is ready.
pub fn timeout_ms(deadline_ns: ?u64) i32 {
    const deadline = deadline_ns orelse return -1;
    const now = monotonic_ns();
    if (now >= deadline) return 0;
    // divCeil fails only on a zero divisor.
    const remaining_ms = std.math.divCeil(u64, deadline - now, std.time.ns_per_ms) catch
        unreachable;
    return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
}

/// Wall-clock time in nanoseconds since the Unix epoch. For timestamps other machines can read.
/// It jumps when the clock is set, so two of them never make a duration.
pub fn realtime_ns() u64 {
    return clock_ns(.REALTIME);
}

fn clock_ns(clock: linux.clockid_t) u64 {
    var time: linux.timespec = undefined;
    const result = linux.clock_gettime(clock, &time);
    // Both clocks always exist on Linux, and the pointer is valid.
    assert(linux.errno(result) == .SUCCESS);
    assert(time.sec >= 0);
    assert(time.nsec >= 0);
    return @as(u64, @intCast(time.sec)) * ns_per_s + @as(u64, @intCast(time.nsec));
}

/// Sleeps for about `duration_ms`. For tests: the agent itself waits on timers, never sleeps.
pub fn sleep_ms(duration_ms: u64) void {
    const request = timespec_from_ms(duration_ms);
    // Waking early because of a signal is fine for a test.
    _ = linux.nanosleep(&request, null);
}

fn timespec_from_ms(duration_ms: u64) linux.timespec {
    return .{
        .sec = @intCast(@divFloor(duration_ms, std.time.ms_per_s)),
        .nsec = @intCast((duration_ms % std.time.ms_per_s) * ns_per_ms),
    };
}

/// A timerfd that becomes readable every `period_ms`, counted from when it was armed.
pub const Timer = struct {
    fd: i32,

    pub fn init(period_ms: u32) error{Unexpected}!Timer {
        assert(period_ms > 0);
        const result = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(result) != .SUCCESS) return error.Unexpected;
        const timer = Timer{ .fd = @intCast(result) };
        errdefer _ = linux.close(timer.fd);

        const period = timespec_from_ms(period_ms);
        const schedule = linux.itimerspec{ .it_interval = period, .it_value = period };
        if (linux.errno(linux.timerfd_settime(timer.fd, .{}, &schedule, null)) != .SUCCESS) {
            return error.Unexpected;
        }
        return timer;
    }

    /// Fires every `period_ms` from now on, the first time `period_ms` from now.
    pub fn period_set(timer: *const Timer, period_ms: u32) error{Unexpected}!void {
        assert(period_ms > 0);
        const period = timespec_from_ms(period_ms);
        const schedule = linux.itimerspec{ .it_interval = period, .it_value = period };
        if (linux.errno(linux.timerfd_settime(timer.fd, .{}, &schedule, null)) != .SUCCESS) {
            return error.Unexpected;
        }
    }

    pub fn deinit(timer: *Timer) void {
        assert(timer.fd >= 0);
        _ = linux.close(timer.fd);
        timer.* = undefined;
    }

    /// How many periods passed since the last call: more than one when the reader was late.
    /// Clears the readiness. 0 when the timer had not fired.
    pub fn expirations_read(timer: *const Timer) error{Unexpected}!u64 {
        var expirations: u64 = 0;
        const result = linux.read(timer.fd, std.mem.asBytes(&expirations), @sizeOf(u64));
        switch (linux.errno(result)) {
            .SUCCESS => {
                assert(result == @sizeOf(u64));
                assert(expirations > 0);
                return expirations;
            },
            .AGAIN => return 0,
            else => return error.Unexpected,
        }
    }
};

test "both clocks advance, and the wall clock is a real date" {
    const monotonic_start = monotonic_ns();
    const realtime_start = realtime_ns();
    sleep_ms(20);
    try std.testing.expect(monotonic_ns() - monotonic_start >= 15 * ns_per_ms);
    try std.testing.expect(realtime_ns() - realtime_start >= 15 * ns_per_ms);
    try std.testing.expect(realtime_start > 1_577_836_800 * ns_per_s); // After 1 January 2020.
}

test "a timer fires once per period, and reads 0 before it has fired" {
    var timer = try Timer.init(20);
    defer timer.deinit();

    try std.testing.expectEqual(@as(u64, 0), try timer.expirations_read());
    sleep_ms(50);
    const expirations = try timer.expirations_read();
    try std.testing.expect(expirations >= 1);
    try std.testing.expect(expirations <= 3);
    try std.testing.expectEqual(@as(u64, 0), try timer.expirations_read());
}

test "a new period takes effect at once" {
    var timer = try Timer.init(1000);
    defer timer.deinit();
    try timer.period_set(10);
    sleep_ms(35);
    try std.testing.expect(try timer.expirations_read() >= 2);
}

test "the timeout reaches the deadline, and none means wait for ever" {
    try std.testing.expectEqual(@as(i32, -1), timeout_ms(null));
    try std.testing.expectEqual(@as(i32, 0), timeout_ms(0));
    const timeout = timeout_ms(monotonic_ns() + 50 * ns_per_ms);
    try std.testing.expect(timeout > 0);
    try std.testing.expect(timeout <= 50);
}
