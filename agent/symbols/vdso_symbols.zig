//! A `.symtab` for the vDSO.

const std = @import("std");
const assert = std.debug.assert;
const target = @import("../target/target.zig");
const elf = @import("shared").elf;
const eh_frame = @import("../elf/elf.zig").eh_frame;

const sym_bytes = 24;
const stt_func = 2;
const jmp_opcode = 0xe9;
const jmp_bytes = 5;
const stub_bytes_max = 16;
const symbols_max = 256;
const segments_max = 4;

pub const Symbols = struct {
    symtab: []const u8,
    strtab: []const u8,
};

pub fn symbols(arena: std.mem.Allocator, image: []const u8) !?Symbols {
    const dynsym = section_bytes(image, ".dynsym") orelse return null;
    const dynstr = section_bytes(image, ".dynstr") orelse return null;
    const count = dynsym.len / sym_bytes;
    if (count == 0 or count > symbols_max) return null;

    var segments_buffer: [segments_max]elf.Segment = undefined;
    const segments_count = elf.segments_executable(image, &segments_buffer) catch return null;
    const segments = segments_buffer[0..segments_count];

    const symtab = try arena.alloc(u8, 2 * count * sym_bytes);
    @memcpy(symtab[0 .. count * sym_bytes], dynsym[0 .. count * sym_bytes]);
    var added: usize = 0;
    for (0..count) |index| {
        const stub = dynsym[index * sym_bytes ..][0..sym_bytes];
        const body = body_of(image, segments, stub) orelse continue;
        const out = symtab[(count + added) * sym_bytes ..][0..sym_bytes];
        @memcpy(out, stub);
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
    size: u64,
};

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
    if (file_offset(segments, start) == null) return null;
    return .{ .start = start, .size = unwind_size(image, start) orelse 0 };
}

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

const testing = std.testing;
const os = @import("../os/os.zig");

fn name_at(strtab: []const u8, sym: []const u8) []const u8 {
    const at = std.mem.readInt(u32, sym[0..4], .little);
    return std.mem.sliceTo(strtab[at..], 0);
}

test "the vDSO's stubs lead to bodies that get the stubs' names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const image = own.vdso_image() orelse return error.SkipZigTest;
    const found = (try symbols(arena.allocator(), image.bytes)) orelse return error.SkipZigTest;

    const dynsym = section_bytes(image.bytes, ".dynsym").?;
    try testing.expect(found.symtab.len > dynsym.len);
    try testing.expectEqualSlices(u8, dynsym, found.symtab[0..dynsym.len]);

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
    sym[4] = 0x12;
    std.mem.writeInt(u64, sym[8..16], 0x10, .little);
    std.mem.writeInt(u64, sym[16..24], 5, .little);

    image[0x10] = jmp_opcode;
    std.mem.writeInt(i32, image[0x11..0x15], 0x20, .little);
    try testing.expectEqual(@as(u64, 0x35), body_of(&image, &segments, &sym).?.start);

    std.mem.writeInt(i32, image[0x11..0x15], 0x1000, .little);
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
    image[0x10] = 0x90;
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
    image[0x10] = jmp_opcode;
    std.mem.writeInt(i32, image[0x11..0x15], 0x20, .little);
    std.mem.writeInt(u64, sym[16..24], 64, .little);
    try testing.expectEqual(@as(?Body, null), body_of(&image, &segments, &sym));
}
