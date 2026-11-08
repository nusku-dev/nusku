//! The server's log, under the scope "server". Quiet until the program installs a logger.
//!
//!     const log = @import("log.zig").server;
//!     log.info("run started", .{ .target = target, .pid = pid });

const std = @import("std");
const logger = @import("log");
/// The longest build ID the server accepts (see symbols/id_set.zig).
const id_bytes_max = 256;

pub const server = logger.scope("server");

/// Room for the hex of any build ID the server accepts.
pub const hex_bytes_max = 2 * id_bytes_max;

/// KiB, rounded up: a small binary shows as 1, not 0.
pub fn kib(bytes: u64) u64 {
    return std.math.divCeil(u64, bytes, 1024) catch unreachable;
}

/// A build ID in hex, as `readelf -n` shows it.
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
