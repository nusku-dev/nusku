//! Names for the code of the vDSO. The kernel exports each vDSO function as a stub of one
//! instruction, `jmp` to the real body, and strips every other symbol: a sample is nearly
//! always in a body, which has no name of its own. So the agent writes a `.symtab` for it: the
//! exported symbols, plus one for each body, named after the stub that jumps there and sized
//! by the vDSO's own unwind entry for it.
//!
//! The bytes come from the agent's own image of the vDSO, which is the target's (see
//! target/vdso.zig), so nothing here is read from the target.

const std = @import("std");
const assert = std.debug.assert;
const elf = @import("shared").elf;
const eh_frame = @import("../unwind/eh_frame.zig");

/// The size of one Elf64_Sym.
const sym_bytes = 24;
const stt_func = 2;
/// `jmp rel32`: one opcode byte, then a 4-byte offset from the end of the instruction.
const jmp_opcode = 0xe9;
const jmp_bytes = 5;
/// A stub is the jump and some padding. A larger function that happens to start with a jump
/// is real code, and keeps its own name.
const stub_bytes_max = 16;
/// The vDSO exports a dozen symbols. Far more is not a vDSO.
const symbols_max = 256;
const segments_max = 4;

pub const Symbols = struct {
    /// The exported symbols, then one per body.
    symtab: []const u8,
    /// The vDSO's own `.dynstr`: the bodies share the names of their stubs.
    strtab: []const u8,
};

/// The `.symtab` to send for the vDSO image `image`, or null when it has no stubs to follow.
/// `symtab` is in `arena`; `strtab` points into `image`.
pub fn symbols(arena: std.mem.Allocator, image: []const u8) !?Symbols {
    const dynsym = section_bytes(image, ".dynsym") orelse return null;
    const dynstr = section_bytes(image, ".dynstr") orelse return null;
    const count = dynsym.len / sym_bytes;
    if (count == 0 or count > symbols_max) return null;

    var segments_buffer: [segments_max]elf.Segment = undefined;
    const segments_count = elf.segments_executable(image, &segments_buffer) catch return null;
    const segments = segments_buffer[0..segments_count];

    // The exported symbols first, as they are, then at most one body for each.
    const symtab = try arena.alloc(u8, 2 * count * sym_bytes);
    @memcpy(symtab[0 .. count * sym_bytes], dynsym[0 .. count * sym_bytes]);
    var added: usize = 0;
    for (0..count) |index| {
        const stub = dynsym[index * sym_bytes ..][0..sym_bytes];
        const body = body_of(image, segments, stub) orelse continue;
        const out = symtab[(count + added) * sym_bytes ..][0..sym_bytes];
        @memcpy(out, stub); // The same name, kind and section.
        std.mem.writeInt(u64, out[8..16], body.start, .little);
        std.mem.writeInt(u64, out[16..24], body.size, .little);
        added += 1;
    }
    if (added == 0) return null;
    assert(added <= count);
    return .{ .symtab = symtab[0 .. (count + added) * sym_bytes], .strtab = dynstr };
}

const Body = struct {
    start: u64,
    /// 0 when the vDSO has no unwind entry for it: the server then lets it last until the
    /// next function.
    size: u64,
};

/// Where the stub `sym` jumps to, if it is a stub.
fn body_of(image: []const u8, segments: []const elf.Segment, sym: *const [sym_bytes]u8) ?Body {
    if (sym[4] & 0xf != stt_func) return null;
    const value = std.mem.readInt(u64, sym[8..16], .little);
    const size = std.mem.readInt(u64, sym[16..24], .little);
    if (size < jmp_bytes or size > stub_bytes_max) return null;

    const offset = file_offset(segments, value) orelse return null;
    if (image.len < jmp_bytes or offset > image.len - jmp_bytes) return null;
    const code = image[@intCast(offset)..][0..jmp_bytes];
    if (code[0] != jmp_opcode) return null;

    const relative: i64 = std.mem.readInt(i32, code[1..5], .little);
    const start = value +% jmp_bytes +% @as(u64, @bitCast(relative));
    if (file_offset(segments, start) == null) return null; // Jumps out of the vDSO.
    return .{ .start = start, .size = unwind_size(image, start) orelse 0 };
}

/// How far the unwind entry that covers `address` reaches past it: the end of its function.
fn unwind_size(image: []const u8, address: u64) ?u64 {
    const section = (elf.find(image, ".eh_frame") catch return null) orelse return null;
    const bytes = elf.bytes_of(image, section) orelse return null;
    var iterator = (eh_frame.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
    while (iterator.next() catch return null) |fde| {
        if (address >= fde.pc_begin and address < fde.pc_end) return fde.pc_end - address;
    }
    return null;
}

fn section_bytes(image: []const u8, name: []const u8) ?[]const u8 {
    const section = (elf.find(image, name) catch return null) orelse return null;
    return elf.bytes_of(image, section);
}

fn file_offset(segments: []const elf.Segment, address: u64) ?u64 {
    for (segments) |segment| {
        if (address < segment.vaddr or address - segment.vaddr >= segment.filesz) continue;
        return segment.offset + (address - segment.vaddr);
    }
    return null;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const vdso = @import("../target/vdso.zig");

fn name_at(strtab: []const u8, sym: []const u8) []const u8 {
    const at = std.mem.readInt(u32, sym[0..4], .little);
    return std.mem.sliceTo(strtab[at..], 0);
}

test "the vDSO's stubs lead to bodies that get the stubs' names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    // A kernel whose vDSO exports its functions directly has nothing to add.
    const found = (try symbols(arena.allocator(), image.bytes)) orelse return error.SkipZigTest;

    const dynsym = section_bytes(image.bytes, ".dynsym").?;
    try testing.expect(found.symtab.len > dynsym.len);
    try testing.expectEqualSlices(u8, dynsym, found.symtab[0..dynsym.len]);

    // Every body is a function of the vDSO, outside the stub it is named after.
    var clock_gettime = false;
    var at = dynsym.len;
    while (at < found.symtab.len) : (at += sym_bytes) {
        const body = found.symtab[at..][0..sym_bytes];
        const name = name_at(found.strtab, body);
        try testing.expect(name.len > 0);
        try testing.expectEqual(@as(u8, stt_func), body[4] & 0xf);
        if (std.mem.indexOf(u8, name, "clock_gettime") != null) clock_gettime = true;
    }
    try testing.expect(clock_gettime);
}

test "a jump that is not a stub, or leaves the vDSO, is not followed" {
    var image: [0x100]u8 = @splat(0);
    const segments = [_]elf.Segment{.{ .offset = 0, .vaddr = 0, .filesz = image.len }};
    var sym: [sym_bytes]u8 = @splat(0);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u64, sym[8..16], 0x10, .little);
    std.mem.writeInt(u64, sym[16..24], 5, .little);

    // jmp +0x20: from 0x15 to 0x35.
    image[0x10] = jmp_opcode;
    std.mem.writeInt(i32, image[0x11..0x15], 0x20, .little);
    try testing.expectEqual(@as(u64, 0x35), body_of(&image, &segments, &sym).?.start);

    // Out of the image.
    std.mem.writeInt(i32, image[0x11..0x15], 0x1000, .little);
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
    // Not a jump.
    image[0x10] = 0x90;
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
    // Too big to be a stub.
    image[0x10] = jmp_opcode;
    std.mem.writeInt(i32, image[0x11..0x15], 0x20, .little);
    std.mem.writeInt(u64, sym[16..24], 64, .little);
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
}
