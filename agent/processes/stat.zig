const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;
const Directory = @import("../os/directory.zig").Directory;
const process = @import("../os/process.zig");

/// What /proc/<pid>/stat says about one process.
pub const Stat = struct {
    pid: u32,
    name_buffer: [name_bytes_max]u8,
    name_len: u8,
    /// CPU time used since the process started, all its threads together (user + system),
    /// in clock ticks.
    cpu_ticks: u64,
    /// When the process started, in clock ticks since boot.
    start_ticks: u64,

    /// The kernel keeps 15 bytes of a name today; the room for more costs nothing.
    pub const name_bytes_max = 64;

    /// Fills `stat` from /proc/<pid>/stat. `error.ProcessNotFound` when the process ended
    /// before we read it: the caller skips it.
    pub fn read(stat: *Stat, pid: u32) !void {
        assert(process.pid_valid(pid));
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid});

        // A missing /proc/<pid> means the same as ESRCH: the process is gone.
        var file = File.open(path) catch |err| switch (err) {
            error.NotFound => return error.ProcessNotFound,
            else => return err,
        };
        defer file.deinit();

        // A stat line is about 300 bytes; 52 fields of 20 digits each would still fit.
        var buffer: [2048]u8 = undefined;
        const len = try file.read_at(&buffer, 0);
        if (len == buffer.len) return error.Malformed;

        stat.* = try stat_parse(pid, buffer[0..len]);
    }

    /// The line is "pid (name) state field4 field5 ...". The name can hold spaces and ')', so
    /// it ends at the LAST ')'. After it the fields are counted from 3 (state), as in proc(5).
    fn stat_parse(pid: u32, text: []const u8) !Stat {
        const open_at = std.mem.indexOfScalar(u8, text, '(') orelse return error.Malformed;
        const close_at = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.Malformed;
        if (close_at < open_at) return error.Malformed;
        const proc_name = text[open_at + 1 .. close_at];

        var fields = std.mem.tokenizeAny(u8, text[close_at + 1 ..], " \n");
        var utime: u64 = 0;
        var stime: u64 = 0;
        var starttime: ?u64 = null;
        var field: u32 = 3;
        while (fields.next()) |value| : (field += 1) {
            switch (field) {
                14 => utime = try number_parse(value),
                15 => stime = try number_parse(value),
                22 => {
                    starttime = try number_parse(value);
                    break; // Nothing after it is needed.
                },
                else => {},
            }
        }

        var stat = Stat{
            .pid = pid,
            .name_buffer = undefined,
            .name_len = @intCast(@min(proc_name.len, Stat.name_bytes_max)),
            .cpu_ticks = utime + stime,
            .start_ticks = starttime orelse return error.Malformed,
        };
        @memcpy(stat.name_buffer[0..stat.name_len], proc_name[0..stat.name_len]);
        return stat;
    }

    /// A field of the stat line. Anything but digits means the line is not what we expect.
    fn number_parse(value: []const u8) error{Malformed}!u64 {
        return std.fmt.parseInt(u64, value, 10) catch error.Malformed;
    }

    pub fn name(stat: *const Stat) []const u8 {
        return stat.name_buffer[0..stat.name_len];
    }
};

// -- tests --
const testing = std.testing;

test "stat_parse finds the name by its last ')', and the fields after it" {
    // utime (14) is 111, stime (15) is 222, starttime (22) is 999.
    const line = "42 (a) b (c) S 1 2 3 4 5 6 7 8 9 10 111 222 13 14 15 16 17 18 999 20\n";
    const stat = try Stat.stat_parse(42, line);
    try testing.expectEqualStrings("a) b (c", stat.name());
    try testing.expectEqual(@as(u64, 333), stat.cpu_ticks);
    try testing.expectEqual(@as(u64, 999), stat.start_ticks);
}

test "stat_parse refuses lines that are not a stat line" {
    try testing.expectError(error.Malformed, Stat.stat_parse(42, "42 no parentheses"));
    try testing.expectError(error.Malformed, Stat.stat_parse(42, "42 (short) S 1 2"));
    try testing.expectError(error.Malformed, Stat.stat_parse(42, "42 ) x ( S 1 2"));
    // Letters in utime.
    const letters = "42 (x) S 1 2 3 4 5 6 7 8 9 10 abc 222 13 14 15 16 17 18 999 20\n";
    try testing.expectError(error.Malformed, Stat.stat_parse(42, letters));
}

test "a long name is cut to the room there is" {
    const long = "x" ** 100;
    const line = "1 (" ++ long ++ ") S 1 2 3 4 5 6 7 8 9 10 1 1 13 14 15 16 17 18 5 20\n";
    const stat = try Stat.stat_parse(1, line);
    try testing.expectEqual(@as(usize, Stat.name_bytes_max), stat.name().len);
}
