//! Processes: checking a pid, and the child processes tests profile.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const timer = @import("timer.zig");

/// A pid the agent may target. 0 means "nothing" to the kernel program, and kill(0) or
/// kill(-1) would reach a whole process group or every process, so those never get past here.
pub fn pid_valid(pid: u32) bool {
    if (pid == 0) return false;
    return pid <= std.math.maxInt(i32);
}

pub fn current_pid() u32 {
    const pid = linux.getpid();
    assert(pid > 0);
    return @intCast(pid);
}

// ------------------------------------------------------------------------- for tests only

/// Forks a child that keeps one CPU busy for `duration_ms`, then exits.
pub fn burner_spawn(duration_ms: u64) error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        cpu_burn(duration_ms);
        std.c._exit(0);
    }
    return @intCast(pid);
}

/// Forks a child that sleeps for a long time without using the CPU.
pub fn sleeper_spawn() error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        timer.sleep_ms(30 * std.time.ms_per_s);
        std.c._exit(0);
    }
    return @intCast(pid);
}

/// Keeps the calling thread busy for `duration_ms`, in its own code.
///
/// The clock is read only every `burn_iterations_per_check` iterations: reading it is a vDSO
/// call, and a loop that read it every time would spend most of its samples inside the vDSO,
/// which has no unwind table, so the tests would profile the clock instead of this loop.
pub fn cpu_burn(duration_ms: u64) void {
    const deadline_ns = timer.monotonic_ns() + duration_ms * std.time.ns_per_ms;
    var counter: u64 = 0;
    while (timer.monotonic_ns() < deadline_ns) {
        var iteration: u32 = 0;
        while (iteration < burn_iterations_per_check) : (iteration += 1) {
            counter +%= iteration;
            std.mem.doNotOptimizeAway(counter);
        }
    }
}

/// About 50 µs of work per clock read in a Debug build: far finer than any test's duration.
const burn_iterations_per_check = 1 << 16;

/// Kills the child, without waiting for it.
pub fn child_kill(pid: u32) void {
    assert(pid_valid(pid));
    _ = linux.kill(@intCast(pid), .KILL);
}

/// Kills the child if it still runs, and waits for it, so it leaves no zombie.
pub fn child_reap(pid: u32) void {
    child_kill(pid);
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

test "pid_valid refuses the pids that mean more than one process" {
    try std.testing.expect(!pid_valid(0));
    try std.testing.expect(pid_valid(1));
    try std.testing.expect(pid_valid(std.math.maxInt(i32)));
    try std.testing.expect(!pid_valid(@as(u32, std.math.maxInt(i32)) + 1));
}
