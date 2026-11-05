//! The server's log: every line the server writes goes through here, under the scope "server".
//!
//!     const log = @import("log.zig").server;     // "../log.zig" from a folder
//!     log.info("run started", .{ .target = target, .pid = pid });
//!
//! It writes to the logger the program installs (logger/, `log.setDefault`), and does nothing
//! without one, so the server is quiet as a library until its host asks for logs. Nothing on
//! the path of every report or every frame logs: lines come once per run, per binary, per
//! query, or when something is refused or goes wrong.

const std = @import("std");
const logger = @import("log");
const id_bytes_max = @import("store/id_set.zig").id_bytes_max;

pub const server = logger.scope("server");

/// Room for the hex of any build ID the server accepts.
pub const hex_bytes_max = 2 * id_bytes_max;

/// A size for a log line, in KiB, rounded up: a small binary shows as 1, not as 0.
pub fn kib(bytes: u64) u64 {
    return std.math.divCeil(u64, bytes, 1024) catch unreachable;
}

/// A build ID as `readelf -n` shows it, for a log line: the bytes as hex, in `buffer`.
pub fn hex(buffer: *[hex_bytes_max]u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    const length = @min(bytes.len, id_bytes_max);
    for (bytes[0..length], 0..) |byte, index| {
        buffer[2 * index] = digits[byte >> 4];
        buffer[2 * index + 1] = digits[byte & 0xf];
    }
    return buffer[0 .. 2 * length];
}

test "kib rounds up, so only nothing is 0" {
    try std.testing.expectEqual(@as(u64, 0), kib(0));
    try std.testing.expectEqual(@as(u64, 1), kib(1));
    try std.testing.expectEqual(@as(u64, 2), kib(1025));
}

test "hex shows a build ID the way readelf does" {
    var buffer: [hex_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings("49ad9c00ff", hex(&buffer, "\x49\xad\x9c\x00\xff"));
    try std.testing.expectEqualStrings("", hex(&buffer, ""));
}
