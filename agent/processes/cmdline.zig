const std = @import("std");
const assert = std.debug.assert;
const process = @import("../os/os.zig").process;
const File = @import("shared").File;

/// The command line of a process: its arguments, separated by spaces, as `ps` shows them.
pub const CmdLine = struct {
    buffer: [bytes_max]u8,
    len: u16,

    /// What a row on a terminal can show; a whole command line can be megabytes.
    pub const bytes_max = 256;

    pub fn read(cmdline: *CmdLine, pid: u32) !void {
        assert(process.pid_valid(pid));
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/cmdline", .{pid});

        // A missing /proc/<pid> means the same as ESRCH: the process is gone.
        var file = File.open(path) catch |err| switch (err) {
            error.NotFound => return error.ProcessNotFound,
            else => return err,
        };
        defer file.deinit();

        // One byte more than kept: a full read says the command is longer.
        var buffer: [bytes_max + 1]u8 = undefined;
        const len = try file.read_at(&buffer, 0);

        const raw = buffer[0..len];
        const kept = raw[0..@min(raw.len, bytes_max)];
        const raw_text = std.mem.trimEnd(u8, kept, "\x00");

        var cmd_line = CmdLine{
            .buffer = undefined,
            .len = 0,
        };

        for (cmd_line.buffer[0..raw_text.len], raw_text) |*out, byte| {
            out.* = if (byte == 0) ' ' else byte;
        }
        cmd_line.len = @intCast(raw_text.len);

        cmdline.* = cmd_line;
    }

    pub fn text(cmdline: *const CmdLine) []const u8 {
        return cmdline.buffer[0..cmdline.len];
    }
};

const testing = std.testing;

test "read gives this process's command line" {
    var cmdline: CmdLine = undefined;
    try cmdline.read(process.current_pid());
    try testing.expect(cmdline.text().len > 0);
    try testing.expectError(error.ProcessNotFound, cmdline.read(std.math.maxInt(i32)));
}
