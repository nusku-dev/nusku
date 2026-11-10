//! Processes: checking a pid.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const File = @import("shared").File;

pub fn pid_valid(pid: u32) bool {
    if (pid == 0) return false;
    return pid <= std.math.maxInt(i32);
}

pub fn current_pid() u32 {
    const pid = linux.getpid();
    assert(pid > 0);
    return @intCast(pid);
}

pub fn file_open(pid: u32, path: []const u8) error{Unreadable}!File {
    var path_buffer: [4200]u8 = undefined;
    const full = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/root{s}", .{ pid, path }) catch
        return error.Unreadable;
    return File.open(full) catch error.Unreadable;
}

pub fn mapping_open(pid: u32, path: []const u8, start: u64, end: u64) error{Unreadable}!File {
    if (file_open(pid, path)) |file| return file else |_| {}
    if (start >= end) return error.Unreadable;

    var path_buffer: [64]u8 = undefined;
    const mapping = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/map_files/{x}-{x}", .{
        pid,
        start,
        end,
    }) catch unreachable;
    return File.open(mapping) catch error.Unreadable;
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
