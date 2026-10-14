const std = @import("std");
const timer = @import("times.zig");

extern "c" fn getpid() c_int;
extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getppid() c_int;

const SYS_pidfd_open = 434;

const EPERM = 1;
const ESRCH = 3;
const EINTR = 4;
const ENOSYS = 38;

pub const CLOCK_MONOTONIC = 1;
/// A pid of 0 means "profile nothing" to our kernel program, and kill(0, ...) or kill(-1, ...)
/// would mean "my process group" or "everyone", so such values must never get past this check.
pub fn isValidPid(pid: u32) bool {
    return pid > 0 and pid <= std.math.maxInt(i32);
}

pub fn currentPid() u32 {
    return @intCast(getpid());
}

pub fn pidfdSyscall(pid: u32) !c_int {
    const rc = syscall(SYS_pidfd_open, @as(c_long, pid), @as(c_long, 0));
    if (rc < 0) return switch (errno()) {
        ESRCH => error.ProcessNotFound,
        EPERM => error.PermissionDenied,
        ENOSYS => error.NotSupported,
        else => error.Unexpected,
    };
    const pid_fd: c_int = @intCast(rc);
    return pid_fd;
}

pub fn fdClose(fd: c_int) void {
    _ = close(fd);
}

fn errno() c_int {
    return std.c._errno().*;
}

// testing helper
extern "c" fn fork() c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

pub fn spawnBurner(ms: u64) !u32 {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const until = timer.nowMs() + ms;
        var x: u64 = 0;
        while (timer.nowMs() < until) x +%= 1;
        std.mem.doNotOptimizeAway(x);
        _exit(0);
    }
    return @intCast(pid);
}

pub fn reap(pid: u32) void {
    _ = kill(@intCast(pid), 9); // SIGKILL; harmless if it already exited
    _ = waitpid(@intCast(pid), null, 0);
}

pub fn spawnSignaller(delay_ms: u64, sig: c_int) !u32 {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        timer.sleepMs(delay_ms);
        _ = kill(getppid(), sig);
        _exit(0);
    }
    return @intCast(pid);
}
