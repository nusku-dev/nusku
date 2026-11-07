const std = @import("std");
const assert = std.debug.assert;
const process = @import("../os/process.zig");
const File = @import("shared").File;

pub const Statm = struct {
    resident_pages: u64,

    pub fn read(statm: *Statm, pid: u32) !void {
        assert(process.pid_valid(pid));
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/statm", .{pid});

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

        var fields = std.mem.tokenizeAny(u8, buffer[0..len], " \n");
        _ = fields.next() orelse return error.Malformed; // size
        const resident = fields.next() orelse return error.Malformed;

        statm.* = .{ .resident_pages = try number_parse(resident) };
    }

    /// A field of the stat line. Anything but digits means the line is not what we expect.
    fn number_parse(value: []const u8) error{Malformed}!u64 {
        return std.fmt.parseInt(u64, value, 10) catch error.Malformed;
    }
};

const testing = std.testing;
