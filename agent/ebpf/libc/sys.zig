const std = @import("std");
const c = @import("import.zig").clibs;
const err = @import("error.zig");

const Error = err.Error;
const fromErrno = err.fromErrno;

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn getpid() c_int;

const CLOCK_MONOTONIC = 1;
const ESRCH = 3; // "no such process"

/// A pid of 0 means "profile nothing" to our kernel program, and kill(0, ...) or kill(-1, ...)
/// would mean "my process group" or "everyone", so such values must never get past this check.
pub fn isValidPid(pid: u32) bool {
    return pid > 0 and pid <= std.math.maxInt(i32);
}

/// Signal 0 sends nothing, it only checks. The caller has validated the pid.
pub fn processExists(pid: u32) bool {
    std.debug.assert(isValidPid(pid));
    if (kill(@intCast(pid), 0) == 0) return true;
    // EPERM means it exists but we may not signal it. Only ESRCH means it is gone.
    return std.c._errno().* != ESRCH;
}

/// Number of CPU slots the kernel may use (includes offline ones).
pub fn numPossibleCpus() Error!u32 {
    const n = c.libbpf_num_possible_cpus();
    if (n < 0) return fromErrno(-n);
    std.debug.assert(n > 0);
    return @intCast(n);
}

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

pub fn nowMs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    std.debug.assert(rc == 0); // CLOCK_MONOTONIC always exists on Linux
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn sleepMs(ms: u64) void {
    const req = Timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&req, null); // waking early because of a signal is fine
}

pub fn nowNs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    std.debug.assert(rc == 0); // CLOCK_MONOTONIC always exists on Linux
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn sleepNs(ns: u64) void {
    const req = Timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = nanosleep(&req, null); // waking early because of a signal is fine
}

pub fn currentPid() u32 {
    return @intCast(getpid());
}
