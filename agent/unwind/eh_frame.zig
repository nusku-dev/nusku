//! Reader for the `.eh_frame` section: the unwind information that C, C++, Rust, Zig and every
//! other gcc or LLVM based compiler writes (DWARF call frame information). It stays in stripped
//! binaries, because exceptions need it at run time.
//!
//! This file only splits the section into entries and finds the address range of each; what
//! the instructions inside them mean is cfi_machine.zig's job. The `.debug_frame` section uses
//! a slightly different layout and is not read here.
const std = @import("std");

pub const Error = error{ Truncated, Malformed, Unsupported };

/// The part shared by many FDEs.
pub const Cie = struct {
    /// Where this entry starts in the section.
    offset: usize,
    code_align: u64,
    data_align: i64,
    /// The register that holds the return address (16 on x86-64).
    ra_register: u64,
    /// How `pc_begin` and `pc_range` of its FDEs are written (a DW_EH_PE value).
    fde_encoding: u8,
    /// A signal frame: the frame below it was interrupted, it did not make a call.
    signal_frame: bool,
    /// Whether its FDEs carry an augmentation data field.
    has_augmentation: bool,
    /// The instructions that set the starting rules of every function it describes.
    instructions: []const u8,
};

/// What describes one function, or part of one.
pub const Fde = struct {
    /// First address covered, as an address in the file's own address space.
    pc_begin: u64,
    /// One past the last address covered. Equal to `pc_begin` for a function the linker dropped.
    pc_end: u64,
    cie: Cie,
    instructions: []const u8,
};

pub const EhFrame = struct {
    /// The bytes of the section.
    bytes: []const u8,
    /// The address of the section's first byte once loaded. Pointers inside it are written
    /// relative to where they are stored, so this is needed to turn them into addresses.
    vaddr: u64,

    pub fn iterator(self: EhFrame) Iterator {
        return .{ .section = self };
    }
};

pub const Iterator = struct {
    section: EhFrame,
    pos: usize = 0,
    cie_cache: ?Cie = null,

    /// The next FDE, or null at the end. CIEs are not returned; each FDE carries its own.
    pub fn next(self: *Iterator) Error!?Fde {
        const bytes = self.section.bytes;
        while (self.pos < bytes.len) {
            var reader = Reader{ .bytes = bytes, .pos = self.pos, .end = bytes.len };
            const length = try reader.int(u32);
            if (length == 0) { // the terminator
                self.pos = bytes.len;
                return null;
            }
            // The 64-bit form, which nothing uses.
            if (length == 0xffffffff) return error.Unsupported;
            const body_end = std.math.add(usize, reader.pos, length) catch return error.Malformed;
            if (body_end > bytes.len) return error.Truncated;
            reader.end = body_end;
            self.pos = body_end;

            const id_pos = reader.pos;
            const id = try reader.int(u32);
            if (id == 0) continue; // a CIE: it is read when an FDE points at it
            if (id > id_pos) return error.Malformed;
            const cie = try self.cie_at(id_pos - id);

            const pc_begin = try pointer_read(&reader, cie.fde_encoding, self.section.vaddr);
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

    fn cie_at(self: *Iterator, offset: usize) Error!Cie {
        if (self.cie_cache) |cached| {
            if (cached.offset == offset) return cached;
        }
        const bytes = self.section.bytes;
        var reader = Reader{ .bytes = bytes, .pos = offset, .end = bytes.len };
        const length = try reader.int(u32);
        if (length == 0 or length == 0xffffffff) return error.Malformed;
        const body_end = std.math.add(usize, reader.pos, length) catch return error.Malformed;
        if (body_end > bytes.len) return error.Truncated;
        reader.end = body_end;
        if ((try reader.int(u32)) != 0) return error.Malformed; // the FDE does not point at a CIE

        const version = try reader.int(u8);
        if (version != 1 and version != 3) return error.Unsupported;
        const augmentation = try reader.cstring();

        var cie = Cie{
            .offset = offset,
            .code_align = try reader.uleb(),
            .data_align = try reader.sleb(),
            .ra_register = 0,
            .fde_encoding = 0, // DW_EH_PE_absptr, the default
            .signal_frame = false,
            .has_augmentation = false,
            .instructions = &.{},
        };
        cie.ra_register = if (version == 1) try reader.int(u8) else try reader.uleb();

        if (augmentation.len > 0) {
            // Without a leading 'z' there is no length to skip the data by, so no way to read it.
            if (augmentation[0] != 'z') return error.Unsupported;
            cie.has_augmentation = true;
            const data_len = std.math.cast(usize, try reader.uleb()) orelse return error.Malformed;
            if (data_len > reader.end - reader.pos) return error.Truncated;
            const data_end = reader.pos + data_len;
            for (augmentation[1..]) |letter| switch (letter) {
                'R' => cie.fde_encoding = try reader.int(u8),
                // How the language-specific data pointers are written.
                'L' => _ = try reader.int(u8),
                'P' => try pointer_skip(&reader, try reader.int(u8)), // the personality routine
                'S' => cie.signal_frame = true,
                'B' => {}, // an ARM feature that has no data
                else => return error.Unsupported,
            };
            reader.pos = data_end;
        }
        cie.instructions = bytes[reader.pos..reader.end];
        self.cie_cache = cie;
        return cie;
    }
};

// What a DW_EH_PE value means: the low 4 bits say how the number is stored, bits 4 to 6 say what
// it is relative to.
fn formatted_read(reader: *Reader, format: u8) Error!u64 {
    return switch (format) {
        0x00, 0x04, 0x0c => try reader.int(u64), // an address, unsigned 8 bytes, signed 8 bytes
        0x01 => try reader.uleb(),
        0x02 => try reader.int(u16),
        0x03 => try reader.int(u32),
        0x09 => @bitCast(try reader.sleb()),
        0x0a => @bitCast(@as(i64, @as(i16, @bitCast(try reader.int(u16))))),
        0x0b => @bitCast(@as(i64, @as(i32, @bitCast(try reader.int(u32))))),
        else => error.Unsupported,
    };
}

/// A pointer to code or data: for `.eh_frame` it is absolute or relative to where it is stored.
fn pointer_read(reader: *Reader, encoding: u8, section_vaddr: u64) Error!u64 {
    if (encoding == 0xff or encoding & 0x80 != 0) return error.Unsupported; // omitted, or indirect
    const field_vaddr = section_vaddr +% @as(u64, reader.pos);
    const raw = try formatted_read(reader, encoding & 0x0f);
    return switch (encoding & 0x70) {
        0x00 => raw,
        0x10 => field_vaddr +% raw,
        else => error.Unsupported,
    };
}

/// Reads past a pointer whose value is not needed (the personality routine of a CIE).
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
            if (shift == 63 and byte & 0x7e != 0) return error.Malformed; // does not fit in 64 bits
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

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn u32_put(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn u64_put(b: []u8, at: usize, v: u64) void {
    std.mem.writeInt(u64, b[at..][0..8], v, .little);
}

/// The CIE that gcc and clang write for x86-64. It is 24 bytes long.
const x86_cie = [_]u8{
    0x14, 0x00, 0x00, 0x00, // length 20
    0x00, 0x00, 0x00, 0x00, // CIE id
    0x01, // version
    'z', 'R', 0x00, // augmentation
    0x01, // code alignment 1
    0x78, // data alignment -8
    0x10, // return address register 16
    0x01, // augmentation data length
    0x1b, // FDEs are written pc-relative, signed 4 bytes
    0x0c, 0x07, 0x08, // DW_CFA_def_cfa: register 7, offset 8
    0x90, 0x01, // DW_CFA_offset: register 16 at cfa-8
    0x00, 0x00, // padding
};

const base_vaddr = 0x2000;

/// Writes an FDE for the CIE at offset 0, with pc-relative signed 4 byte fields as the CIE above
/// says, and returns where the next entry starts.
fn fde_put(b: []u8, at: usize, target: u64, range: u32, instructions: []const u8) usize {
    const body: u32 = @intCast(4 + 4 + 4 + 1 + instructions.len);
    u32_put(b, at, body);
    u32_put(b, at + 4, @intCast(at + 4)); // how far back the CIE is
    const field = at + 8;
    const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(base_vaddr + field)));
    std.mem.writeInt(i32, b[field..][0..4], rel, .little);
    u32_put(b, field + 4, range);
    b[field + 8] = 0; // no augmentation data
    @memcpy(b[field + 9 ..][0..instructions.len], instructions);
    return at + 4 + body;
}

/// The CIE, then two FDEs, then the terminator. 68 bytes.
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
    try testing.expect((try it.next()) == null); // and it stays at the end
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

    // pc-relative, unsigned 4 bytes (0x13): the same bytes as the signed form for this value.
    @memset(&b, 0);
    @memcpy(b[0..x86_cie.len], &x86_cie);
    b[16] = 0x13;
    var end = fde_put(&b, x86_cie.len, 0x3000, 0x40, &.{0x00});
    var it = (EhFrame{ .bytes = b[0 .. end + 4], .vaddr = base_vaddr }).iterator();
    var fde = (try it.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0x3000), fde.pc_begin);
    try testing.expectEqual(@as(u64, 0x3040), fde.pc_end);

    // absolute, 8 bytes (0x00): the address is stored as it is, 8 bytes for the range too.
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
        0x18, 0x00, 0x00, 0x00, // length 24
        0x00, 0x00, 0x00, 0x00, // CIE id
        0x01, // version
        'z', 'P', 'L', 'R', 0x00, // augmentation
        0x01, 0x78, 0x10, // alignments, return address register
        0x07, // augmentation data length: 1 + 4 + 1 + 1
        // The personality routine: its encoding, then a 4 byte pointer.
        0x9b,
        0x11,
        0x22,
        0x33,
        0x44,
        0x1b, // how the language-specific data pointers are written
        0x1b, // how FDE addresses are written
        0x0c, 0x07, 0x08, // DW_CFA_def_cfa
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
        0x11, 0x00, 0x00, 0x00, // length 17
        0x00, 0x00, 0x00, 0x00, // CIE id
        0x01, // version
        'z', 'R', 'S', 0x00, // augmentation
        0x01, 0x78, 0x10, // alignments, return address register
        0x01, // augmentation data length
        0x1b, // FDE encoding
        0x0c, 0x07, 0x08, // DW_CFA_def_cfa
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

    // The second entry claims to be longer than the section.
    var it = (EhFrame{ .bytes = bytes[0..60], .vaddr = base_vaddr }).iterator();
    try testing.expect((try it.next()) != null);
    try testing.expectError(error.Truncated, it.next());

    // An FDE whose pointer to its CIE points before the start of the section.
    _ = fdes_two(&b);
    u32_put(&b, x86_cie.len + 4, 1000);
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Malformed, it.next());

    // An FDE whose pointer to its CIE points at something that is not a CIE.
    _ = fdes_two(&b);
    u32_put(&b, x86_cie.len + 4, 4);
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Malformed, it.next());

    // A CIE version this reader does not know.
    _ = fdes_two(&b);
    b[8] = 4;
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    // An augmentation letter this reader does not know.
    _ = fdes_two(&b);
    b[10] = 'X';
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    // An address encoding this reader does not handle (data-relative).
    _ = fdes_two(&b);
    b[16] = 0x3b;
    it = (EhFrame{ .bytes = b[0..68], .vaddr = base_vaddr }).iterator();
    try testing.expectError(error.Unsupported, it.next());

    // The 64-bit entry length form.
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

    // Too long to be a 64-bit number, and cut short.
    const too_long = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    reader = Reader{ .bytes = &too_long, .pos = 0, .end = too_long.len };
    try testing.expectError(error.Malformed, reader.uleb());
    reader = Reader{ .bytes = &.{ 0x80, 0x80 }, .pos = 0, .end = 2 };
    try testing.expectError(error.Truncated, reader.uleb());
}
