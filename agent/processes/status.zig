const std = @import("std");
const assert = std.debug.assert;
const process = @import("../os/os.zig").process;
const File = @import("shared").File;

pub const Status = struct {
    uid: u32,
    rss_kb: u64,
    threads: u32,

    pub fn read(statm: *Status, pid: u32) !void {
        assert(process.pid_valid(pid));
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/status", .{pid});

        var file = File.open(path) catch |err| switch (err) {
            error.NotFound => return error.ProcessNotFound,
            else => return err,
        };
        defer file.deinit();

        var buffer: [4096]u8 = undefined;
        const len = try file.read_at(&buffer, 0);
        statm.* = try status_parse(buffer[0..len]);
    }

    fn status_parse(text: []const u8) !Status {
        var uid: ?u32 = null;
        var rss_kb: u64 = 0;
        var threads: u32 = 0;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Uid:")) {
                var ids = std.mem.tokenizeAny(u8, line["Uid:".len..], " \t");
                _ = ids.next() orelse return error.Malformed;

                const effective = ids.next() orelse return error.Malformed;
                uid = std.math.cast(u32, try number_parse(effective)) orelse return error.Malformed;
            }
            if (std.mem.startsWith(u8, line, "VmRSS:")) {
                var words = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
                rss_kb = try number_parse(words.next() orelse return error.Malformed);
            }

            if (std.mem.startsWith(u8, line, "Threads:")) {
                var words = std.mem.tokenizeAny(u8, line["Threads:".len..], " \t");
                const count = try number_parse(words.next() orelse return error.Malformed);
                threads = std.math.cast(u32, count) orelse return error.Malformed;
            }
        }

        return .{
            .uid = uid orelse return error.Malformed,
            .rss_kb = rss_kb,
            .threads = threads,
        };
    }

    fn number_parse(value: []const u8) error{Malformed}!u64 {
        return std.fmt.parseInt(u64, value, 10) catch error.Malformed;
    }
};

const testing = std.testing;

const status_test =
    "Name:\tsh\nUmask:\t0022\nState:\tS (sleeping)\n" ++
    "Uid:\t1000\t0\t0\t0\nGid:\t1000\t1000\t1000\t1000\n" ++
    "VmPeak:\t    9000 kB\nVmRSS:\t    1234 kB\nThreads:\t1\n";

test "status_parse takes the effective uid, not the real one, and VmRSS" {
    const status = try Status.status_parse(status_test);
    try testing.expectEqual(@as(u32, 0), status.uid);
    try testing.expectEqual(@as(u64, 1234), status.rss_kb);
}

test "a kernel thread has no VmRSS: its memory is 0" {
    const status = try Status.status_parse("Name:\tkthreadd\nUid:\t0\t0\t0\t0\nThreads:\t1\n");
    try testing.expectEqual(@as(u64, 0), status.rss_kb);
}

test "status_parse refuses a status without a whole Uid line" {
    try testing.expectError(error.Malformed, Status.status_parse("Name:\tsh\n"));
    try testing.expectError(error.Malformed, Status.status_parse("Uid:\t1000\n"));
    try testing.expectError(error.Malformed, Status.status_parse("Uid:\t1000\tabc\t0\t0\n"));
}

test "read gives this process's own uid and some memory" {
    var status: Status = undefined;
    try status.read(process.current_pid());
    try testing.expectEqual(std.os.linux.geteuid(), status.uid);
    try testing.expect(status.rss_kb > 0);
}

test "read says ProcessNotFound for a pid no process has" {
    var status: Status = undefined;
    try testing.expectError(error.ProcessNotFound, status.read(std.math.maxInt(i32)));
}

test "status_parse takes the thread count" {
    const status = try Status.status_parse(status_test);
    try testing.expectEqual(@as(u32, 1), status.threads);
}
