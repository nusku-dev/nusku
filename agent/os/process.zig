//! Processes: checking a pid, and this process's own.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

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

test "pid_valid refuses the pids that mean more than one process" {
    try std.testing.expect(!pid_valid(0));
    try std.testing.expect(pid_valid(1));
    try std.testing.expect(pid_valid(std.math.maxInt(i32)));
    try std.testing.expect(!pid_valid(@as(u32, std.math.maxInt(i32)) + 1));
}
