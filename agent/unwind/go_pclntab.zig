//! Go's pclntab: unwind tables even stripped Go binaries have.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ Truncated, Unsupported, Malformed };

const magic_go1_18: u32 = 0xfffffff0;
const magic_go1_20: u32 = 0xfffffff1;
const header_size = 72;

pub const flag_top_frame: u8 = 1 << 0;
pub const flag_sp_write: u8 = 1 << 1;

pub const Function = struct {
    entry: u64,
    next_entry: u64,
    flag: u8,
    pcsp: []const u8,
};

pub const Pclntab = struct {
    bytes: []const u8,
    text_start: u64,
    function_count: u32,
    functab_offset: u64,
    pctab_offset: u64,
    flag_offset: u32,

    pub fn init(bytes: []const u8, text_vaddr: u64) Error!Pclntab {
        if (bytes.len < header_size) return error.Truncated;
        const magic = int_read(u32, bytes, 0) catch unreachable;
        const flag_offset: u32 = switch (magic) {
            magic_go1_18 => 37,
            magic_go1_20 => 41,
            else => return error.Unsupported,
        };
        if (bytes[6] != 1) return error.Unsupported;
        if (bytes[7] != 8) return error.Unsupported;

        const function_count = std.math.cast(u32, try int_read(u64, bytes, 8)) orelse
            return error.Malformed;
        const text_start_header = try int_read(u64, bytes, 24);
        const pclntab = Pclntab{
            .bytes = bytes,
            .text_start = if (text_start_header != 0) text_start_header else text_vaddr,
            .function_count = function_count,
            .pctab_offset = try int_read(u64, bytes, 56),
            .functab_offset = try int_read(u64, bytes, 64),
            .flag_offset = flag_offset,
        };
        const functab_size = (@as(u64, function_count) + 1) * 8;
        if (pclntab.functab_offset > bytes.len) return error.Truncated;
        if (functab_size > bytes.len - pclntab.functab_offset) return error.Truncated;
        if (pclntab.pctab_offset > bytes.len) return error.Truncated;
        return pclntab;
    }

    pub fn function(pclntab: *const Pclntab, index: u32) Error!Function {
        assert(index < pclntab.function_count);
        const entry_at = pclntab.functab_offset + @as(u64, index) * 8;
        const entry_offset = try int_read(u32, pclntab.bytes, entry_at);
        const next_entry_offset = try int_read(u32, pclntab.bytes, entry_at + 8);
        const func_offset = try int_read(u32, pclntab.bytes, entry_at + 4);
        if (next_entry_offset < entry_offset) return error.Malformed;

        const func_at = pclntab.functab_offset + func_offset;
        if (try int_read(u32, pclntab.bytes, func_at) != entry_offset) return error.Malformed;
        const pcsp_offset = try int_read(u32, pclntab.bytes, func_at + 16);
        const flag = try int_read(u8, pclntab.bytes, func_at + pclntab.flag_offset);

        const pcsp_at = pclntab.pctab_offset + pcsp_offset;
        if (pcsp_at > pclntab.bytes.len) return error.Truncated;
        return .{
            .entry = pclntab.text_start + entry_offset,
            .next_entry = pclntab.text_start + next_entry_offset,
            .flag = flag,
            .pcsp = if (pcsp_offset == 0) &.{} else pclntab.bytes[@intCast(pcsp_at)..],
        };
    }
};

pub const Range = struct { start: u64, end: u64, sp_delta: i32 };

pub const PcspIterator = struct {
    bytes: []const u8,
    position: usize = 0,
    pc: u64,
    value: i64 = -1,
    first: bool = true,

    pub fn next(iterator: *PcspIterator) Error!?Range {
        const value_delta_encoded = try varint_read(iterator.bytes, &iterator.position);
        if (value_delta_encoded == 0 and !iterator.first) return null;
        iterator.first = false;

        const value_delta: i64 = if (value_delta_encoded & 1 != 0)
            -@as(i64, @intCast(value_delta_encoded >> 1)) - 1
        else
            @intCast(value_delta_encoded >> 1);
        const pc_delta = try varint_read(iterator.bytes, &iterator.position);

        iterator.value = std.math.add(i64, iterator.value, value_delta) catch
            return error.Malformed;
        const start = iterator.pc;
        iterator.pc = std.math.add(u64, iterator.pc, pc_delta) catch return error.Malformed;
        const sp_delta = std.math.cast(i32, iterator.value) orelse return error.Malformed;
        return .{ .start = start, .end = iterator.pc, .sp_delta = sp_delta };
    }
};

fn varint_read(bytes: []const u8, position: *usize) Error!u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (shift < 35) : (shift += 7) {
        if (position.* >= bytes.len) return error.Truncated;
        const byte = bytes[position.*];
        position.* += 1;
        if (shift == 28 and byte > 0x0f) return error.Malformed;
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return result;
    }
    return error.Malformed;
}

fn int_read(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    const end = std.math.add(u64, offset, @sizeOf(T)) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

const testing = std.testing;

test "pcsp: the ranges of a function that pushes rbp, grows its frame, and returns" {
    const table = [_]u8{
        0x02, 0x10,
        0x10, 0x0a,
        0xa0, 0x02,
        0x88, 0x01,
        0x9f, 0x02,
        0x01, 0x0f,
        0x01, 0x00,
    };
    var iterator = PcspIterator{ .bytes = &table, .pc = 0x1000 };
    const expected = [_]Range{
        .{ .start = 0x1000, .end = 0x1010, .sp_delta = 0 },
        .{ .start = 0x1010, .end = 0x101a, .sp_delta = 8 },
        .{ .start = 0x101a, .end = 0x10a2, .sp_delta = 152 },
        .{ .start = 0x10a2, .end = 0x10a3, .sp_delta = 8 },
        .{ .start = 0x10a3, .end = 0x10a4, .sp_delta = 0 },
    };
    for (expected) |range| {
        const found = (try iterator.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(range, found);
    }
    try testing.expect((try iterator.next()) == null);
}

test "pcsp: a table cut short, or with a number past 32 bits, is an error" {
    var cut = PcspIterator{ .bytes = &.{ 0x02, 0x90 }, .pc = 0 };
    try testing.expectError(error.Truncated, cut.next());

    var long = PcspIterator{ .bytes = &.{ 0x02, 0xff, 0xff, 0xff, 0xff, 0x7f }, .pc = 0 };
    try testing.expectError(error.Malformed, long.next());
}

test "a header of another Go version, or another architecture, is refused" {
    var header: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 0xfffffffb, .little);
    header[6] = 1;
    header[7] = 8;
    try testing.expectError(error.Unsupported, Pclntab.init(&header, 0x401000));

    std.mem.writeInt(u32, header[0..4], magic_go1_20, .little);
    header[7] = 4;
    try testing.expectError(error.Unsupported, Pclntab.init(&header, 0x401000));
    try testing.expectError(error.Truncated, Pclntab.init(header[0..10], 0x401000));
}
