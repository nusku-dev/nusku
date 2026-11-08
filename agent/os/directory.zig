//! The names in a directory, read with getdents64. Includes "." and "..": the caller filters.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const shared = @import("shared");
const File = shared.File;

pub const FilError = shared.FileError;

const buffer_bytes = 8192;
const interrupt_retries_max = 16;

/// One record is: inode (8 bytes), offset (8), record length (2), type (1), then the name
/// and a zero.
const length_at = 16;
const name_at = 19;

pub const Directory = struct {
    file: File,
    buffer: [buffer_bytes]u8 align(8),
    /// The part of `buffer` that holds records, and where the next one starts.
    len: usize,
    at: usize,

    pub fn open(path: [:0]const u8) FilError!Directory {
        return .{ .file = try File.open(path), .buffer = undefined, .len = 0, .at = 0 };
    }

    pub fn deinit(directory: *Directory) void {
        directory.file.deinit();
        directory.* = undefined;
    }

    /// The next name, valid until the next call, or null at the end.
    pub fn next(directory: *Directory) FilError!?[]const u8 {
        if (directory.at >= directory.len) {
            if (try directory.refill() == 0) return null;
        }
        assert(directory.at < directory.len);

        const record = directory.buffer[directory.at..directory.len];
        assert(record.len > name_at);
        const length = std.mem.readInt(u16, record[length_at..][0..2], builtin.cpu.arch.endian());
        assert(length > name_at and length <= record.len);
        directory.at += length;
        return std.mem.sliceTo(record[name_at..length], 0);
    }

    /// Reads the next batch of records. Returns how many bytes: 0 is the end.
    fn refill(directory: *Directory) FilError!usize {
        var interrupts: u32 = 0;
        while (true) {
            const buffer = &directory.buffer;
            const result = linux.getdents64(directory.file.fd, buffer, buffer.len);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    directory.len = result;
                    directory.at = 0;
                    return result;
                },
                .INTR => {
                    interrupts += 1;
                    if (interrupts < interrupt_retries_max) continue;
                    return error.Interrupted;
                },
                // The directory went away while we were reading it (a process that ended).
                .NOENT => return error.ProcessNotFound,
                else => return error.Unexpected,
            }
        }
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "the names of /proc include this process, and a missing directory is not found" {
    var directory = try Directory.open("/proc");
    defer directory.deinit();

    var own_buffer: [16]u8 = undefined;
    const own = std.fmt.bufPrint(&own_buffer, "{d}", .{linux.getpid()}) catch unreachable;

    var count: u32 = 0;
    var found = false;
    while (try directory.next()) |name| {
        count += 1;
        if (std.mem.eql(u8, name, own)) found = true;
    }
    try testing.expect(found);
    try testing.expect(count >= 5);

    try testing.expectError(error.NotFound, Directory.open("/no/such/directory"));
}
