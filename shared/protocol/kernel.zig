//! How kernel frames are named.

const std = @import("std");
const elf = @import("../elf.zig");

pub const path = "[kernel]";

pub const id_bytes_max = 64;

pub const segment = elf.Segment{ .offset = 0, .vaddr = 0, .filesz = std.math.maxInt(u64) };

pub fn id(buffer: *[id_bytes_max]u8, build_id: ?[]const u8, text_address: ?u64) ?[]const u8 {
    const kernel_id = build_id orelse return null;
    const text = text_address orelse return null;
    if (kernel_id.len == 0 or kernel_id.len + 8 > id_bytes_max) return null;
    @memcpy(buffer[0..kernel_id.len], kernel_id);
    std.mem.writeInt(u64, buffer[kernel_id.len..][0..8], text, .little);
    return buffer[0 .. kernel_id.len + 8];
}

test "the identity is the build ID and _text, and needs both" {
    var buffer: [id_bytes_max]u8 = undefined;
    const both = id(&buffer, "\xab\xcd", 0x1122).?;
    try std.testing.expectEqualSlices(u8, "\xab\xcd\x22\x11\x00\x00\x00\x00\x00\x00", both);
    try std.testing.expectEqual(@as(?[]const u8, null), id(&buffer, null, 0x1122));
    try std.testing.expectEqual(@as(?[]const u8, null), id(&buffer, "\xab", null));
}
