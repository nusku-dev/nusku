//! Processes: checking a pid, this process's own, and the files a process sees.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const File = @import("shared").File;

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

/// The file at `path` as process `pid` sees it (/proc/<pid>/root), so files that exist only
/// inside a container work too. The caller closes it.
pub fn file_open(pid: u32, path: []const u8) error{Unreadable}!File {
    // A path can be up to 4096 bytes; the prefix "/proc/4294967295/root" is 21 more.
    var path_buffer: [4200]u8 = undefined;
    const full = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/root{s}", .{ pid, path }) catch
        return error.Unreadable;
    return File.open(full) catch error.Unreadable;
}

test "pid_valid refuses the pids that mean more than one process" {
    try std.testing.expect(!pid_valid(0));
    try std.testing.expect(pid_valid(1));
    try std.testing.expect(pid_valid(std.math.maxInt(i32)));
    try std.testing.expect(!pid_valid(@as(u32, std.math.maxInt(i32)) + 1));
}

test "file_open reads a file as the process sees it" {
    var file = try file_open(current_pid(), "/bin/sh");
    file.deinit();
    try std.testing.expectError(error.Unreadable, file_open(current_pid(), "/no/such/file"));
}
