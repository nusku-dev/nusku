const std = @import("std");
const CLOCK_MONOTONIC = @import("sys.zig").CLOCK_MONOTONIC;

extern "c" fn sigemptyset(set: *SigSet) c_int;
extern "c" fn sigaddset(set: *SigSet, signum: c_int) c_int;
extern "c" fn pthread_sigmask(how: c_int, set: *const SigSet, old: ?*SigSet) c_int;
extern "c" fn signalfd(fd: c_int, mask: *const SigSet, flags: c_int) c_int;
extern "c" fn timerfd_create(clock: c_int, flags: c_int) c_int;
// musl's sigset_t is 128 bytes (16 longs). The signal numbers are the same on x86_64 and aarch64.
pub const SigSet = extern struct {
    bits: [16]c_ulong,
};
comptime {
    std.debug.assert(@sizeOf(SigSet) == 128);
}

const SIGINT = 2;
const SIGTERM = 15;

pub fn makeStopSignalSet() !SigSet {
    var set: SigSet = undefined;

    if (sigemptyset(&set) != 0) {
        return error.SignalSetInitFailed;
    }

    if (sigaddset(&set, SIGINT) != 0) {
        return error.SignalSetAddFailed;
    }

    if (sigaddset(&set, SIGTERM) != 0) {
        return error.SignalSetAddFailed;
    }

    return set;
}

const SignalMaskHow = enum(c_int) {
    block = 0,
    unblock = 1,
    set_mask = 2,
};

pub fn setSignalMask(
    how: SignalMaskHow,
    set: *const SigSet,
    old_set: ?*SigSet,
) !void {
    const rc = pthread_sigmask(
        @intFromEnum(how),
        set,
        old_set,
    );

    if (rc != 0) {
        return error.SignalMaskOperationFailed;
    }
}

const SFD_NONBLOCK = 0o4000;
const SFD_CLOEXEC = 0o2000000;

pub fn createSignalFd(signals: *const SigSet) !c_int {
    const fd = signalfd(
        -1,
        signals,
        SFD_NONBLOCK | SFD_CLOEXEC,
    );

    if (fd < 0) {
        return error.SignalFdCreateFailed;
    }

    return fd;
}

const TFD_NONBLOCK = 0o4000;
const TFD_CLOEXEC = 0o2000000;

pub fn createTimerFd() !c_int {
    const fd = timerfd_create(
        CLOCK_MONOTONIC,
        TFD_NONBLOCK | TFD_CLOEXEC,
    );

    if (fd < 0) {
        return error.TimerFdCreateFailed;
    }

    return fd;
}
