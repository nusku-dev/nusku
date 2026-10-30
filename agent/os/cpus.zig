//! Which CPUs are online. CPUs come and go at run time (hotplug, cloud VMs resized, CPUs
//! taken offline for power), so the agent asks again at every report instead of once.

const std = @import("std");
const assert = std.debug.assert;
const file_module = @import("file.zig");
const File = file_module.File;

/// "0-3,5,7-63\n" for 64 CPUs is a few bytes: the kernel writes consecutive CPUs as a range. Only
/// thousands of CPUs online one in two would need more, and such a list is refused (ListTooLong):
/// the caller then tries every possible CPU instead.
const list_size_max = 4096;

pub const Error = error{ ListMalformed, ListTooLong, CpuTooLarge } || file_module.ReadError ||
    file_module.OpenError;

/// Sets `online[cpu]` for every online CPU and clears the others. `online.len` is the number of
/// possible CPUs: a CPU the kernel lists outside of it is an error.
pub fn online_read(online: []bool) Error!void {
    assert(online.len > 0);
    var file = try File.open("/sys/devices/system/cpu/online");
    defer file.deinit();

    var buffer: [list_size_max]u8 = undefined;
    const size = try file.read(&buffer);
    // A full buffer may have cut the list: a cut list would leave CPUs out without saying so.
    if (size == buffer.len) return error.ListTooLong;
    try online_parse(buffer[0..size], online);
}

/// Parses the kernel's CPU list format: comma separated CPUs and inclusive ranges, "0-3,5".
pub fn online_parse(text: []const u8, online: []bool) Error!void {
    @memset(online, false);
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return error.ListMalformed;

    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const first = try number_parse(if (dash) |at| part[0..at] else part);
        const last = if (dash) |at| try number_parse(part[at + 1 ..]) else first;
        if (last < first) return error.ListMalformed;
        if (last >= online.len) return error.CpuTooLarge;
        @memset(online[first .. last + 1], true);
    }
}

fn number_parse(text: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, text, 10) catch error.ListMalformed;
}

test "the CPU list format: single CPUs, ranges, and the newline at the end" {
    var online: [8]bool = undefined;
    try online_parse("0-2,4,6-7\n", &online);
    const expected = [_]bool{ true, true, true, false, true, false, true, true };
    try std.testing.expectEqualSlices(bool, &expected, &online);

    try online_parse("5", &online);
    for (online, 0..) |cpu_online, cpu| try std.testing.expectEqual(cpu == 5, cpu_online);
}

test "malformed lists and CPUs past the possible ones are refused" {
    var online: [4]bool = undefined;
    try std.testing.expectError(error.ListMalformed, online_parse("", &online));
    try std.testing.expectError(error.ListMalformed, online_parse("3-1", &online));
    try std.testing.expectError(error.ListMalformed, online_parse("a", &online));
    try std.testing.expectError(error.ListMalformed, online_parse("0,,1", &online));
    try std.testing.expectError(error.CpuTooLarge, online_parse("0-4", &online));
}

test "this machine has CPU 0 online" {
    var online: [8192]bool = undefined;
    try online_read(&online);
    try std.testing.expect(online[0]);
}
