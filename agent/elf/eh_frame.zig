//! Splits `.eh_frame` into entries and their address ranges.

const std = @import("std");

pub const Error = error{ Truncated, Malformed, Unsupported };

pub const Cie = struct {
    offset: usize,
    code_align: u64,
    data_align: i64,
    ra_register: u64,
    fde_encoding: u8,
    signal_frame: bool,
    has_augmentation: bool,
    instructions: []const u8,
};

pub const Fde = struct {
    pc_begin: u64,
    pc_end: u64,
    cie: Cie,
    instructions: []const u8,
};

pub const Format = enum { eh_frame, debug_frame };

pub const EhFrame = struct {
    bytes: []const u8,
    vaddr: u64,
    format: Format = .eh_frame,

    pub fn iterator(eh_frame: EhFrame) Iterator {
        return .{ .section = eh_frame };
    }
};

pub const Iterator = struct {
    section: EhFrame,
    pos: usize = 0,
    cie_cache: ?Cie = null,

    pub fn next(iterator: *Iterator) Error!?Fde {
        const bytes = iterator.section.bytes;
        while (iterator.pos < bytes.len) {
            var reader = Reader{ .bytes = bytes, .pos = iterator.pos, .end = bytes.len };
            const length = try reader.int(u32);
            if (length == 0) {
                iterator.pos = bytes.len;
                return null;
            }
            if (length == 0xffffffff) return error.Unsupported;
            const body_end = std.math.add(usize, reader.pos, length) catch return error.Malformed;
            if (body_end > bytes.len) return error.Truncated;
            reader.end = body_end;
            iterator.pos = body_end;

            const id_pos = reader.pos;
            const id = try reader.int(u32);
            const cie_offset = switch (iterator.section.format) {
                .eh_frame => offset: {
                    if (id == 0) continue;
                    if (id > id_pos) return error.Malformed;
                    break :offset id_pos - id;
                },
                .debug_frame => offset: {
                    if (id == cie_id_debug_frame) continue;
                    break :offset id;
                },
            };
            const cie = try iterator.cie_at(cie_offset);
            if (iterator.section.format == .debug_frame and cie.fde_encoding & 0x70 != 0) {
                return error.Unsupported;
            }

            const pc_begin = try pointer_read(&reader, cie.fde_encoding, iterator.section.vaddr);
            const range = try formatted_read(&reader, cie.fde_encoding & 0x0f);
            if (@as(i64, @bitCast(range)) < 0) return error.Malformed;
            const pc_end = std.math.add(u64, pc_begin, range) catch return error.Malformed;
            if (cie.has_augmentation) {
                const n = try reader.uleb();
                _ = try reader.take(std.math.cast(usize, n) orelse return error.Malformed);
            }
            return Fde{
                .pc_begin = pc_begin,
                .pc_end = pc_end,
                .cie = cie,
                .instructions = bytes[reader.pos..reader.end],
            };
        }
        return null;
    }

    fn cie_at(iterator: *Iterator, offset: usize) Error!Cie {
        if (iterator.cie_cache) |cached| {
            if (cached.offset == offset) return cached;
        }
        const bytes = iterator.section.bytes;
        var reader = Reader{ .bytes = bytes, .pos = offset, .end = bytes.len };
        const length = try reader.int(u32);
        if (length == 0 or length == 0xffffffff) return error.Malformed;
        const body_end = std.math.add(usize, reader.pos, length) catch return error.Malformed;
        if (body_end > bytes.len) return error.Truncated;
        reader.end = body_end;
        const format = iterator.section.format;
        const cie_id: u32 = if (format == .eh_frame) 0 else cie_id_debug_frame;
        if ((try reader.int(u32)) != cie_id) return error.Malformed;

        const version = try reader.int(u8);
        const version_4 = format == .debug_frame and version == 4;
        if (version != 1 and version != 3 and !version_4) return error.Unsupported;
        const augmentation = try reader.cstring();
        if (version_4) {
            if ((try reader.int(u8)) != 8) return error.Unsupported;
            if ((try reader.int(u8)) != 0) return error.Unsupported;
        }

        var cie = Cie{
            .offset = offset,
            .code_align = try reader.uleb(),
            .data_align = try reader.sleb(),
            .ra_register = 0,
            .fde_encoding = 0,
            .signal_frame = false,
            .has_augmentation = false,
            .instructions = &.{},
        };
        cie.ra_register = if (version == 1) try reader.int(u8) else try reader.uleb();

        if (augmentation.len > 0) {
            if (augmentation[0] != 'z') return error.Unsupported;
            cie.has_augmentation = true;
            const data_len = std.math.cast(usize, try reader.uleb()) orelse return error.Malformed;
            if (data_len > reader.end - reader.pos) return error.Truncated;
            const data_end = reader.pos + data_len;
            for (augmentation[1..]) |letter| switch (letter) {
                'R' => cie.fde_encoding = try reader.int(u8),
                'L' => _ = try reader.int(u8),
                'P' => try pointer_skip(&reader, try reader.int(u8)),
                'S' => cie.signal_frame = true,
                'B' => {},
                else => return error.Unsupported,
            };
            reader.pos = data_end;
        }
        cie.instructions = bytes[reader.pos..reader.end];
        iterator.cie_cache = cie;
        return cie;
    }
};

const cie_id_debug_frame = 0xffffffff;

fn formatted_read(reader: *Reader, format: u8) Error!u64 {
    return switch (format) {
        0x00, 0x04, 0x0c => try reader.int(u64),
        0x01 => try reader.uleb(),
        0x02 => try reader.int(u16),
        0x03 => try reader.int(u32),
        0x09 => @bitCast(try reader.sleb()),
        0x0a => @bitCast(@as(i64, @as(i16, @bitCast(try reader.int(u16))))),
        0x0b => @bitCast(@as(i64, @as(i32, @bitCast(try reader.int(u32))))),
        else => error.Unsupported,
    };
}

fn pointer_read(reader: *Reader, encoding: u8, section_vaddr: u64) Error!u64 {
    if (encoding == 0xff or encoding & 0x80 != 0) return error.Unsupported;
    const field_vaddr = section_vaddr +% @as(u64, reader.pos);
    const raw = try formatted_read(reader, encoding & 0x0f);
    return switch (encoding & 0x70) {
        0x00 => raw,
        0x10 => field_vaddr +% raw,
        else => error.Unsupported,
    };
}

fn pointer_skip(reader: *Reader, encoding: u8) Error!void {
    if (encoding == 0xff) return;
    _ = try formatted_read(reader, encoding & 0x0f);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize,
    end: usize,

    fn take(reader: *Reader, n: usize) Error![]const u8 {
        if (n > reader.end - reader.pos) return error.Truncated;
        const out = reader.bytes[reader.pos .. reader.pos + n];
        reader.pos += n;
        return out;
    }

    fn int(reader: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try reader.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn cstring(reader: *Reader) Error![]const u8 {
        const rest = reader.bytes[reader.pos..reader.end];
        const n = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Truncated;
        reader.pos += n + 1;
        return rest[0..n];
    }

    fn uleb(reader: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try reader.int(u8);
            if (shift >= 64) return error.Malformed;
            if (shift == 63 and byte & 0x7e != 0) return error.Malformed;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn sleb(reader: *Reader) Error!i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try reader.int(u8);
            if (shift >= 64) return error.Malformed;
            result |= @as(i64, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if (byte & 0x80 == 0) break;
        }
        if (shift < 64 and byte & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
        return result;
    }
};

const testing = std.testing;

fn u32_put(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn u64_put(b: []u8, at: usize, v: u64) void {
    std.mem.writeInt(u64, b[at..][0..8], v, .little);
}

const x86_cie = [_]u8{
    0x14, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x01, 'z',  'R',  0x00,
    0x01, 0x78, 0x10, 0x01,
    0x1b, 0x0c, 0x07, 0x08,
    0x90, 0x01, 0x00, 0x00,
};

const base_vaddr = 0x2000;

fn fde_put(b: []u8, at: usize, target: u64, range: u32, instructions: []const u8) usize {
    const body: u32 = @intCast(4 + 4 + 4 + 1 + instructions.len);
    u32_put(b, at, body);
    u32_put(b, at + 4, @intCast(at + 4));
    const field = at + 8;
    const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(base_vaddr + field)));
    std.mem.writeInt(i32, b[field..][0..4], rel, .little);
    u32_put(b, field + 4, range);
    b[field + 8] = 0;
    @memcpy(b[field + 9 ..][0..instructions.len], instructions);
    return at + 4 + body;
}

fn fdes_two(b: *[80]u8) []const u8 {
    @memset(b, 0);
    @memcpy(b[0..x86_cie.len], &x86_cie);
    var at: usize = x86_cie.len;
    at = fde_put(b, at, 0x3000, 0x40, &.{ 0x44, 0x0e, 0x10 });
    at = fde_put(b, at, 0x3040, 0x20, &.{ 0x00, 0x00, 0x00 });
    return b[0 .. at + 4];
}

test "the entries of a section come out with their ranges and the common part" {
    var b: [80]u8 = undefined;
    const bytes = fdes_two(&b);
    var it = (EhFrame{ .bytes = bytes, .vaddr = base_vaddr }).iterator();

    const first = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x3000), first.pc_begin);
    try testing.expectEqual(@as(u64, 0x3040), first.pc_end);
    try testing.expectEqual(@as(u64, 1), first.cie.code_align);
    try testing.expectEqual(@as(i64, -8), first.cie.data_align);
    try testing.expectEqual(@as(u64, 16), first.cie.ra_register);
    try testing.expectEqual(@as(u8, 0x1b), first.cie.fde_encoding);
    try testing.expect(!first.cie.signal_frame);
    const cie_instructions = [_]u8{ 0x0c, 0x07, 0x08, 0x90, 0x01, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &cie_instructions, first.cie.instructions);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0e, 0x10 }, first.instructions);

    const second = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x3040), second.pc_begin);
    try testing.expectEqual(@as(u64, 0x3060), second.pc_end);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00 }, second.instructions);

    try testing.expect((try it.next()) == null);
    try testing.expect((try it.next()) == null);
}

test "a section without a terminator, or without any entry, ends cleanly" {
    var b: [80]u8 = undefined;
    const bytes = fdes_two(&b);

    var it = (EhFrame{ .bytes = bytes[0 .. bytes.len - 4], .vaddr = base_vaddr }).iterator();
    try testing.expect((try it.next()) != null);
    try testing.expect((try it.next()) != null);
    try testing.expect((try it.next()) == null);

    var empty = (EhFrame{ .bytes = &.{}, .vaddr = base_vaddr }).iterator();
    try testing.expect((try empty.next()) == null);

    var only_cie = (EhFrame{ .bytes = bytes[0..x86_cie.len], .vaddr = base_vaddr }).iterator();
    try testing.expect((try only_cie.next()) == null);
}

test "an FDE for a function the linker dropped has an empty range" {
    var b: [80]u8 = undefined;
    @memset(&b, 0);
    @memcpy(b[0..x86_cie.len], &x86_cie);
    const end = fde_put(&b, x86_cie.len, 0x3000, 0, &.{0x00});

    var it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    const fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(fde.pc_begin, fde.pc_end);
}

test "other ways of writing addresses: pc-relative unsigned, and absolute 8 byte" {
    var b: [80]u8 = undefined;

    @memset(&b, 0);
    @memcpy(b[0..x86_cie.len], &x86_cie);
    b[16] = 0x13;
    var end = fde_put(&b, x86_cie.len, 0x3000, 0x40, &.{0x00});
    var it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    var fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x3000), fde.pc_begin);
    try testing.expectEqual(@as(u64, 0x3040), fde.pc_end);

    @memset(&b, 0);
    @memcpy(b[0..x86_cie.len], &x86_cie);
    b[16] = 0x00;
    const at = x86_cie.len;
    u32_put(&b, at, 4 + 8 + 8 + 1 + 3);
    u32_put(&b, at + 4, @intCast(at + 4));
    u64_put(&b, at + 8, 0x401000);
    u64_put(&b, at + 16, 0x80);
    end = at + 4 + 24;
    it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x401000), fde.pc_begin);
    try testing.expectEqual(@as(u64, 0x401080), fde.pc_end);
}

test "a CIE with a personality routine and language data is read past correctly" {
    var b: [80]u8 = undefined;
    @memset(&b, 0);
    const cie = [_]u8{
        0x18, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 'z',  'P',  'L',
        'R',  0x00, 0x01, 0x78,
        0x10, 0x07, 0x9b, 0x11,
        0x22, 0x33, 0x44, 0x1b,
        0x1b, 0x0c, 0x07, 0x08,
    };
    @memcpy(b[0..cie.len], &cie);
    const end = fde_put(&b, cie.len, 0x3000, 0x40, &.{0x00});

    var it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    const fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0x1b), fde.cie.fde_encoding);
    try testing.expectEqual(@as(u64, 0x3000), fde.pc_begin);
    try testing.expectEqualSlices(u8, &.{ 0x0c, 0x07, 0x08 }, fde.cie.instructions);
}

test "a signal frame CIE is recognised" {
    var b: [80]u8 = undefined;
    @memset(&b, 0);
    const cie = [_]u8{
        0x11, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 'z',  'R',  'S',
        0x00, 0x01, 0x78, 0x10,
        0x01, 0x1b, 0x0c, 0x07,
        0x08,
    };
    @memcpy(b[0..cie.len], &cie);
    const end = fde_put(&b, cie.len, 0x3000, 0x40, &.{0x00});

    var it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    const fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expect(fde.cie.signal_frame);
}

test "malformed sections give errors instead of reading out of bounds" {
    var b: [80]u8 = undefined;
    const bytes = fdes_two(&b);

    var it = (EhFrame{ .bytes = bytes[0..60], .vaddr = base_vaddr }).iterator();
    try testing.expect((try it.next()) != null);
    try testing.expectError(error.Truncated, it.next());

    _ = fdes_two(&b);
    u32_put(&b, x86_cie.len + 4, 1000);
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Malformed, it.next());

    _ = fdes_two(&b);
    u32_put(&b, x86_cie.len + 4, 4);
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Malformed, it.next());

    _ = fdes_two(&b);
    b[8] = 4;
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    _ = fdes_two(&b);
    b[10] = 'X';
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    _ = fdes_two(&b);
    b[16] = 0x3b;
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    _ = fdes_two(&b);
    u32_put(&b, x86_cie.len, 0xffffffff);
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());
}

test "variable length numbers" {
    var reader = Reader{ .bytes = &.{ 0xe5, 0x8e, 0x26 }, .pos = 0, .end = 3 };
    try testing.expectEqual(@as(u64, 624485), try reader.uleb());

    reader = Reader{ .bytes = &.{ 0xc0, 0xbb, 0x78 }, .pos = 0, .end = 3 };
    try testing.expectEqual(@as(i64, -123456), try reader.sleb());

    reader = Reader{ .bytes = &.{0x7f}, .pos = 0, .end = 1 };
    try testing.expectEqual(@as(i64, -1), try reader.sleb());

    reader = Reader{ .bytes = &.{ 0x80, 0x7f }, .pos = 0, .end = 2 };
    try testing.expectEqual(@as(i64, -128), try reader.sleb());

    reader = Reader{ .bytes = &.{0x02}, .pos = 0, .end = 1 };
    try testing.expectEqual(@as(i64, 2), try reader.sleb());

    const too_long = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    reader = Reader{ .bytes = &too_long, .pos = 0, .end = too_long.len };
    try testing.expectError(error.Malformed, reader.uleb());
    reader = Reader{ .bytes = &.{ 0x80, 0x80 }, .pos = 0, .end = 2 };
    try testing.expectError(error.Truncated, reader.uleb());
}

fn debug_frame_two(b: *[128]u8) []const u8 {
    @memset(b, 0);
    const cie = [_]u8{
        0x14, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff,
        0x04, 0x00, 0x08, 0x00,
        0x01, 0x78, 0x10, 0x0c,
        0x07, 0x08, 0x90, 0x01,
        0x00, 0x00, 0x00, 0x00,
    };
    @memcpy(b[0..cie.len], &cie);
    var at: usize = cie.len;
    for ([_][2]u64{ .{ 0x5000, 0x30 }, .{ 0x5030, 0x10 } }) |range| {
        u32_put(b, at, 4 + 8 + 8 + 2);
        u32_put(b, at + 4, 0);
        u64_put(b, at + 8, range[0]);
        u64_put(b, at + 16, range[1]);
        b[at + 24] = 0x41;
        b[at + 25] = 0x00;
        at += 4 + 4 + 8 + 8 + 2;
    }
    return b[0..at];
}

test ".debug_frame: absolute addresses, CIEs found from the start of the section" {
    var b: [128]u8 = undefined;
    const bytes = debug_frame_two(&b);
    const section = EhFrame{ .bytes = bytes, .vaddr = 0, .format = .debug_frame };
    var it = section.iterator();

    const first = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x5000), first.pc_begin);
    try testing.expectEqual(@as(u64, 0x5030), first.pc_end);
    try testing.expectEqual(@as(i64, -8), first.cie.data_align);
    try testing.expectEqual(@as(u64, 16), first.cie.ra_register);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x00 }, first.instructions);
    const second = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x5040), second.pc_end);
    try testing.expectEqual(@as(?Fde, null), try it.next());

    var wrong = (EhFrame{ .bytes = bytes, .vaddr = 0 }).iterator();
    try testing.expectError(error.Malformed, wrong.next());
}
