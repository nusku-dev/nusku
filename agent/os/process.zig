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

/// The file mapped at `start` .. `end` in process `pid`: by `path`, else by the mapping itself
/// (/proc/<pid>/map_files, which needs CAP_SYS_ADMIN), which a sandbox's chroot does not hide.
pub fn mapping_open(pid: u32, path: []const u8, start: u64, end: u64) error{Unreadable}!File {
    if (file_open(pid, path)) |file| return file else |_| {}
    if (start >= end) return error.Unreadable; // No mapping to go through.

    // "/proc/4294967295/map_files/" and two addresses of 16 hex digits.
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

test "mapping_open finds a mapping by its addresses when its path does not open" {
    const maps = @import("../target/process_maps.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mappings = try maps.read(arena.allocator(), current_pid());
    const own = for (mappings) |mapping| {
        if (mapping.path.len > 0 and mapping.path[0] == '/') break mapping;
    } else return error.SkipZigTest;

    // The path as it is: opens like `file_open`.
    var file = try mapping_open(current_pid(), own.path, own.start, own.end);
    file.deinit();

    // A path that is not there, as in a sandbox: only the mapping is left, and opening it
    // needs CAP_SYS_ADMIN.
    const hidden = mapping_open(current_pid(), "/no/such/file", own.start, own.end);
    if (std.os.linux.geteuid() != 0) {
        try std.testing.expectError(error.Unreadable, hidden);
        return;
    }
    var through_mapping = try hidden;
    defer through_mapping.deinit();
    var magic: [4]u8 = undefined;
    _ = try through_mapping.read_at(&magic, 0);
    try std.testing.expectEqualSlices(u8, "\x7fELF", &magic);
}
