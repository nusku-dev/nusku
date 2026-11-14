//! Reading DWARF: Reads bytes, integers, strings, and encoded numbers safely.

const std = @import("std");

pub const Error = error{ OutOfMemory, Malformed };

pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn init(r: *Reader, bytes: []const u8, at: usize) void {
        std.debug.assert(at <= bytes.len);

        r.* = Reader{
            .bytes = bytes,
            .at = at,
        };
    }

    pub fn done(r: *const Reader) bool {
        return r.at >= r.bytes.len;
    }

    pub fn take(r: *Reader, n: u64) Error![]const u8 {
        if (r.at > r.bytes.len or n > r.bytes.len - r.at) return error.Malformed;
        const out = r.bytes[r.at..][0..@intCast(n)];
        r.at += @intCast(n);
        return out;
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        const bytes = try r.take(size);
        return std.mem.readInt(T, bytes[0..size], .little);
    }

    pub fn sized(r: *Reader, size: u8) Error!u64 {
        return switch (size) {
            1 => try r.int(u8),
            2 => try r.int(u16),
            3 => try r.int(u24),
            4 => try r.int(u32),
            8 => try r.int(u64),
            else => error.Malformed,
        };
    }

    pub fn uleb(r: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try r.int(u8);
            if (shift < 64) result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
            if (shift > 70) return error.Malformed;
        }
    }

    pub fn sleb(r: *Reader) Error!i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try r.int(u8);
            if (shift < 64) result |= @as(i64, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if (byte & 0x80 == 0) {
                if (shift < 64 and byte & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
                return result;
            }
            if (shift > 70) return error.Malformed;
        }
    }

    pub fn string(r: *Reader) Error![]const u8 {
        const rest = r.bytes[r.at..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Malformed;
        r.at += end + 1;
        return rest[0..end];
    }

    /// A unit's length; sets `wide` for the 64-bit DWARF format.
    pub fn length(r: *Reader, wide: *bool) Error!u64 {
        const short = try r.int(u32);
        wide.* = short == 0xffffffff;
        if (wide.*) return r.int(u64);
        if (short >= 0xfffffff0) return error.Malformed;
        return short;
    }

    pub fn offset(r: *Reader, wide: bool) Error!u64 {
        return if (wide) r.int(u64) else @as(u64, try r.int(u32));
    }
};

const testing = std.testing;

test "done tracks reader position" {
    var r = Reader{ .bytes = &.{ 1, 2 } };

    try testing.expect(!r.done());

    _ = try r.take(1);
    try testing.expect(!r.done());

    _ = try r.take(1);
    try testing.expect(r.done());
}

test "take returns bytes and advances cursor" {
    var r = Reader{ .bytes = &.{ 10, 20, 30, 40 } };

    const first = try r.take(2);

    try testing.expectEqualSlices(u8, &.{ 10, 20 }, first);
    try testing.expectEqual(@as(usize, 2), r.at);

    const second = try r.take(2);

    try testing.expectEqualSlices(u8, &.{ 30, 40 }, second);
    try testing.expect(r.done());
}

test "take rejects insufficient bytes" {
    var r = Reader{ .bytes = &.{ 1, 2 } };

    try testing.expectError(error.Malformed, r.take(3));

    // Failed reads must not advance the cursor.
    try testing.expectEqual(@as(usize, 0), r.at);
}

test "int reads little endian integers" {
    var r = Reader{
        .bytes = &.{
            0x34, 0x12,
            0x78, 0x56,
            0x34, 0x12,
        },
    };

    try testing.expectEqual(
        @as(u16, 0x1234),
        try r.int(u16),
    );

    try testing.expectEqual(
        @as(u32, 0x12345678),
        try r.int(u32),
    );

    try testing.expect(r.done());
}

test "sized reads supported integer widths" {
    const bytes = [_]u8{
        0x11,
        0x22,
        0x22,
        0x33,
        0x33,
        0x33,
        0x44,
        0x44,
        0x44,
        0x44,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
        0x55,
    };

    var r = Reader{ .bytes = &bytes };

    try testing.expectEqual(@as(u64, 0x11), try r.sized(1));
    try testing.expectEqual(@as(u64, 0x2222), try r.sized(2));
    try testing.expectEqual(@as(u64, 0x333333), try r.sized(3));
    try testing.expectEqual(@as(u64, 0x44444444), try r.sized(4));
    try testing.expectEqual(@as(u64, 0x5555555555555555), try r.sized(8));

    try testing.expect(r.done());
}

test "sized rejects unsupported widths" {
    var r = Reader{ .bytes = &.{ 1, 2, 3 } };

    try testing.expectError(error.Malformed, r.sized(5));
    try testing.expectEqual(@as(usize, 0), r.at);
}

test "uleb reads unsigned values" {
    var r = Reader{
        .bytes = &.{
            0x00, // 0
            0x01, // 1
            0x7f, // 127
            0xe5, 0x8e, 0x26, // 624485
        },
    };

    try testing.expectEqual(@as(u64, 0), try r.uleb());
    try testing.expectEqual(@as(u64, 1), try r.uleb());
    try testing.expectEqual(@as(u64, 127), try r.uleb());
    try testing.expectEqual(@as(u64, 624485), try r.uleb());

    try testing.expect(r.done());
}

test "sleb reads signed values" {
    var r = Reader{
        .bytes = &.{
            0x00, // 0
            0x01, // 1
            0x7f, // -1
            0x40, // -64
            0x80, 0x7f, // -128
        },
    };

    try testing.expectEqual(@as(i64, 0), try r.sleb());
    try testing.expectEqual(@as(i64, 1), try r.sleb());
    try testing.expectEqual(@as(i64, -1), try r.sleb());
    try testing.expectEqual(@as(i64, -64), try r.sleb());
    try testing.expectEqual(@as(i64, -128), try r.sleb());

    try testing.expect(r.done());
}

test "leb128 rejects truncated values" {
    var unsigned = Reader{ .bytes = &.{0x80} };
    try testing.expectError(error.Malformed, unsigned.uleb());

    var signed = Reader{ .bytes = &.{0x80} };
    try testing.expectError(error.Malformed, signed.sleb());
}

test "string reads null terminated strings" {
    var r = Reader{ .bytes = "hello\x00world\x00" };

    try testing.expectEqualStrings("hello", try r.string());
    try testing.expectEqualStrings("world", try r.string());

    try testing.expect(r.done());
}

test "length reads DWARF32" {
    var r = Reader{
        .bytes = &.{ 0x20, 0x00, 0x00, 0x00 },
    };

    var wide = true;

    const len = try r.length(&wide);

    try testing.expectEqual(@as(u64, 32), len);
    try testing.expect(!wide);
}

test "length rejects reserved values" {
    var r = Reader{
        .bytes = &.{ 0xf0, 0xff, 0xff, 0xff },
    };

    var wide = false;

    try testing.expectError(error.Malformed, r.length(&wide));
}

test "offset reads according to DWARF format" {
    var dwarf32 = Reader{
        .bytes = &.{ 0x78, 0x56, 0x34, 0x12 },
    };

    var dwarf64 = Reader{
        .bytes = &.{
            0x88, 0x77, 0x66, 0x55,
            0x44, 0x33, 0x22, 0x11,
        },
    };

    try testing.expectEqual(
        @as(u64, 0x12345678),
        try dwarf32.offset(false),
    );

    try testing.expectEqual(
        @as(u64, 0x1122334455667788),
        try dwarf64.offset(true),
    );
}
