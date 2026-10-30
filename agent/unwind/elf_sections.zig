//! Finds sections and loadable segments of a 64-bit little-endian ELF file, and the load bias
//! of a mapping. Everything in the file is untrusted: each offset is checked before it is read.
const std = @import("std");

pub const Error = error{ NotElf, Truncated, Unsupported };

const shdr_size = 64;
const SHT_NOBITS = 8;
const phdr_size = 56;
const PT_LOAD = 1;

const PF_X = 1;
const page_mask: u64 = 0xfff;

pub const Section = struct {
    kind: u32,
    /// Where the section starts in memory once loaded (0 for sections that are not loaded).
    vaddr: u64,
    /// Where it starts in the file.
    offset: u64,
    size: u64,
};

/// The section called `wanted`, or null if the file has none.
pub fn find(file: []const u8, wanted: []const u8) Error!?Section {
    if (wanted.len == 0) return null;
    if (file.len < 4 or !std.mem.eql(u8, file[0..4], "\x7fELF")) return error.NotElf;
    if (file.len < 64) return error.Truncated;
    if (file[4] != 2 or file[5] != 1) return error.Unsupported;

    const shoff = u64_read(file, 40);
    const shentsize = u16_read(file, 58);
    const shnum = u16_read(file, 60);
    const shstrndx = u16_read(file, 62);
    if (shnum == 0) return null;
    if (shentsize != shdr_size) return error.Unsupported;

    const table_size = std.math.mul(u64, shnum, shdr_size) catch return error.Truncated;
    const table_end = std.math.add(u64, shoff, table_size) catch return error.Truncated;
    if (table_end > file.len) return error.Truncated;
    if (shstrndx >= shnum) return error.Truncated;

    const names = header_at(file, shoff, shstrndx);
    const names_end = std.math.add(u64, names.offset, names.size) catch return error.Truncated;
    if (names_end > file.len) return error.Truncated;
    const name_bytes = file[@intCast(names.offset)..@intCast(names_end)];

    var i: u64 = 0;
    while (i < shnum) : (i += 1) {
        const header = header_at(file, shoff, i);
        if (header.name >= name_bytes.len) continue;
        const rest = name_bytes[header.name..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse continue;
        if (!std.mem.eql(u8, rest[0..end], wanted)) continue;
        return Section{
            .kind = header.kind,
            .vaddr = header.vaddr,
            .offset = header.offset,
            .size = header.size,
        };
    }
    return null;
}

/// What the section holds, or null if it has nothing in the file or points outside it.
pub fn bytes_of(file: []const u8, section: Section) ?[]const u8 {
    if (section.kind == SHT_NOBITS) return null;
    const end = std.math.add(u64, section.offset, section.size) catch return null;
    if (end > file.len) return null;
    return file[@intCast(section.offset)..@intCast(end)];
}

const ProgramHeaders = struct { offset: u64, count: u16 };

/// The program header table of a file, checked to lie inside it. Null if there are none.
fn program_headers(file: []const u8) Error!?ProgramHeaders {
    if (file.len < 4 or !std.mem.eql(u8, file[0..4], "\x7fELF")) return error.NotElf;
    if (file.len < 64) return error.Truncated;
    if (file[4] != 2 or file[5] != 1) return error.Unsupported;

    const phoff = u64_read(file, 32);
    const phentsize = u16_read(file, 54);
    const phnum = u16_read(file, 56);
    if (phnum == 0) return null;
    if (phentsize != phdr_size) return error.Unsupported;
    const table = std.math.mul(u64, phnum, phdr_size) catch return error.Truncated;
    const table_end = std.math.add(u64, phoff, table) catch return error.Truncated;
    if (table_end > file.len) return error.Truncated;
    return .{ .offset = phoff, .count = phnum };
}

pub const Segment = struct { offset: u64, vaddr: u64, filesz: u64 };

/// The loadable, executable segment at `index`, or null if that header is something else.
fn segment_executable(file: []const u8, h: ProgramHeaders, index: u64) ?Segment {
    const base: usize = @intCast(h.offset + index * phdr_size);
    if (u32_read(file, base) != PT_LOAD) return null;
    if (u32_read(file, base + 4) & PF_X == 0) return null;
    return .{
        .offset = u64_read(file, base + 8),
        .vaddr = u64_read(file, base + 16),
        .filesz = u64_read(file, base + 32),
    };
}

/// The executable segment that a mapping belongs to, given the file offset the mapping starts
/// at. The kernel maps whole pages, so a mapping can start in the page where the segment begins.
/// Null if no executable segment has that page.
pub fn segment_mapped(file: []const u8, region_offset: u64) Error!?Segment {
    const h = (try program_headers(file)) orelse return null;
    var i: u64 = 0;
    while (i < h.count) : (i += 1) {
        const s = segment_executable(file, h, i) orelse continue;
        const first_page = s.offset & ~page_mask;
        const end = std.math.add(u64, s.offset, s.filesz) catch continue;
        const rounded = std.math.add(u64, end, page_mask) catch continue;
        const last_page = rounded & ~page_mask;
        if (region_offset >= first_page and region_offset < last_page) return s;
    }
    return null;
}

/// How far a loaded file is from the addresses written in it: the address in memory is the
/// address in the file plus the bias. `region_start` and `region_offset` describe an
/// EXECUTABLE mapping of the file: where it begins in memory and the file offset it maps from.
pub fn load_bias(file: []const u8, region_start: u64, region_offset: u64) Error!?u64 {
    const s = (try segment_mapped(file, region_offset)) orelse return null;
    // Memory address of any file offset X is region_start + (X - region_offset), and its
    // address in the file is vaddr + (X - offset). The bias is the difference.
    return region_start -% region_offset -% s.vaddr +% s.offset;
}

const Header = struct { name: u32, kind: u32, vaddr: u64, offset: u64, size: u64 };

/// The caller has checked that the whole table lies inside the file.
fn header_at(file: []const u8, shoff: u64, index: u64) Header {
    const base: usize = @intCast(shoff + index * shdr_size);
    return .{
        .name = u32_read(file, base),
        .kind = u32_read(file, base + 4),
        .vaddr = u64_read(file, base + 16),
        .offset = u64_read(file, base + 24),
        .size = u64_read(file, base + 32),
    };
}

fn u16_read(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn u32_read(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn u64_read(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

// ------------------------------------------------------------------ tests

fn u16_put(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn u32_put(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn u64_put(b: []u8, at: usize, v: u64) void {
    std.mem.writeInt(u64, b[at..][0..8], v, .little);
}

fn section_put(
    b: []u8,
    index: usize,
    name: u32,
    kind: u32,
    vaddr: u64,
    offset: u64,
    size: u64,
) void {
    const base = 104 + index * shdr_size;
    u32_put(b, base, name);
    u32_put(b, base + 4, kind);
    u64_put(b, base + 16, vaddr);
    u64_put(b, base + 24, offset);
    u64_put(b, base + 32, size);
}

const test_size = 104 + 3 * shdr_size;

/// A file with three sections: 0 is empty; 1 is ".shstrtab", the names, at offset 80; 2 is
/// ".eh_frame", 16 bytes of 0xaa at offset 64, loaded at 0x2000.
fn file_for_test(b: *[test_size]u8) void {
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    u64_put(b, 40, 104); // where the section headers start
    u16_put(b, 58, shdr_size);
    u16_put(b, 60, 3); // how many sections
    u16_put(b, 62, 1); // which one holds the names

    @memset(b[64..80], 0xaa);
    @memcpy(b[80..101], "\x00.shstrtab\x00.eh_frame\x00");

    section_put(b, 1, 1, 3, 0, 80, 21);
    section_put(b, 2, 11, 1, 0x2000, 64, 16);
}

test "find returns where a section is in the file and in memory" {
    var b: [test_size]u8 = undefined;
    file_for_test(&b);

    const eh = (try find(&b, ".eh_frame")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x2000), eh.vaddr);
    try std.testing.expectEqual(@as(u64, 64), eh.offset);
    try std.testing.expectEqual(@as(u64, 16), eh.size);

    const bytes = bytes_of(&b, eh) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 16), bytes.len);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[15]);

    try std.testing.expect((try find(&b, ".shstrtab")) != null);
    try std.testing.expect((try find(&b, ".text")) == null);
    try std.testing.expect((try find(&b, ".eh_fram")) == null); // a prefix is not a match
    try std.testing.expect((try find(&b, "")) == null);
}

test "bytes_of gives nothing for a section outside the file or without contents" {
    var b: [test_size]u8 = undefined;
    file_for_test(&b);
    const eh = (try find(&b, ".eh_frame")).?;

    try std.testing.expect(bytes_of(b[0..70], eh) == null); // the file is cut inside the section
    var bss = eh;
    bss.kind = SHT_NOBITS;
    try std.testing.expect(bytes_of(&b, bss) == null);
    var huge = eh;
    huge.size = std.math.maxInt(u64);
    try std.testing.expect(bytes_of(&b, huge) == null);
}

test "find rejects files that are not usable ELF files" {
    var b: [test_size]u8 = undefined;
    file_for_test(&b);

    try std.testing.expectError(error.NotElf, find("", ".eh_frame"));
    const text = "this is plain text, not a binary";
    try std.testing.expectError(error.NotElf, find(text, ".eh_frame"));
    try std.testing.expectError(error.Truncated, find(b[0..30], ".eh_frame"));

    var thirty_two_bit = b;
    thirty_two_bit[4] = 1;
    try std.testing.expectError(error.Unsupported, find(&thirty_two_bit, ".eh_frame"));

    var past_end = b;
    u64_put(&past_end, 40, 1000); // the section headers would start past the end
    try std.testing.expectError(error.Truncated, find(&past_end, ".eh_frame"));

    var absurd = b;
    u64_put(&absurd, 40, std.math.maxInt(u64) - 8);
    try std.testing.expectError(error.Truncated, find(&absurd, ".eh_frame"));

    var bad_names = b;
    u16_put(&bad_names, 62, 9); // there is no section 9
    try std.testing.expectError(error.Truncated, find(&bad_names, ".eh_frame"));

    var names_outside = b;
    section_put(&names_outside, 1, 1, 3, 0, 80, 5000); // the names claim to be longer than the file
    try std.testing.expectError(error.Truncated, find(&names_outside, ".eh_frame"));
}

test "a file without section headers has no sections" {
    var b: [test_size]u8 = undefined;
    file_for_test(&b);
    u16_put(&b, 60, 0);
    try std.testing.expect((try find(&b, ".eh_frame")) == null);
}

fn program_header_put(
    b: []u8,
    index: usize,
    kind: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    filesz: u64,
) void {
    const base = 64 + index * phdr_size;
    u32_put(b, base, kind);
    u32_put(b, base + 4, flags);
    u64_put(b, base + 8, offset);
    u64_put(b, base + 16, vaddr);
    u64_put(b, base + 32, filesz);
}

const R = 4;
const RX = 5;
const RW = 6;

fn elf_header_for_test(b: *[232]u8, count: u16) void {
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    u64_put(b, 32, 64); // where the program headers start
    u16_put(b, 54, phdr_size);
    u16_put(b, 56, count);
}

/// A read-only segment, then two executable ones, the last with an address that is not its
/// offset plus a constant.
fn layout_for_test(b: *[232]u8) void {
    elf_header_for_test(b, 3);
    program_header_put(b, 0, PT_LOAD, R, 0x0, 0x400000, 0x1000);
    program_header_put(b, 1, PT_LOAD, RX, 0x1000, 0x401000, 0x2000);
    program_header_put(b, 2, PT_LOAD, RX, 0x3e00, 0x404e00, 0x200);
}

test "load_bias: how far the loaded file is from the addresses written in it" {
    var b: [232]u8 = undefined;
    layout_for_test(&b);

    // Not moved: a normal executable. A mapping starts at a page.
    try std.testing.expectEqual(@as(?u64, 0), try load_bias(&b, 0x401000, 0x1000));
    // The page the third segment starts in.
    try std.testing.expectEqual(@as(?u64, 0), try load_bias(&b, 0x404000, 0x3000));
    // Moved to a random base, as for libraries and PIE executables.
    const moved: ?u64 = 0x7f0000000000;
    try std.testing.expectEqual(moved, try load_bias(&b, 0x7f0000401000, 0x1000));
    try std.testing.expectEqual(moved, try load_bias(&b, 0x7f0000404000, 0x3000));
    // A mapping that starts in a later page of the segment.
    try std.testing.expectEqual(moved, try load_bias(&b, 0x7f0000402000, 0x2000));
    // The first segment is read only, so it is not a candidate; and the end of a segment is
    // exclusive.
    try std.testing.expectEqual(@as(?u64, null), try load_bias(&b, 0x7f0000400000, 0x0));
    try std.testing.expectEqual(@as(?u64, null), try load_bias(&b, 0x7f0000500000, 0x4000));
}

test "load_bias: a code segment in the same file page as the segment before it" {
    // The layout LLD writes: a read-only segment from the start of the file, and the code in
    // the same page, so the kernel maps that page twice and the code's mapping has offset 0.
    var b: [232]u8 = undefined;
    elf_header_for_test(&b, 3);
    program_header_put(&b, 0, PT_LOAD, R, 0x0, 0x1000000, 0x4a8);
    program_header_put(&b, 1, PT_LOAD, RX, 0x4b0, 0x10014b0, 0x141);
    program_header_put(&b, 2, PT_LOAD, RW, 0x5f8, 0x10025f8, 0x158);

    try std.testing.expectEqual(@as(?u64, 0), try load_bias(&b, 0x1001000, 0x0));
    const moved: ?u64 = 0x7f0000000000;
    try std.testing.expectEqual(moved, try load_bias(&b, 0x7f0000001000 + 0x1000000, 0x0));
}

test "load_bias rejects what is not a usable ELF file" {
    var b: [232]u8 = undefined;
    layout_for_test(&b);

    try std.testing.expectError(error.NotElf, load_bias("text", 0, 0));
    try std.testing.expectError(error.Truncated, load_bias(b[0..30], 0, 0));

    var past_end = b;
    u64_put(&past_end, 32, 1000);
    try std.testing.expectError(error.Truncated, load_bias(&past_end, 0, 0));

    var no_headers = b;
    u16_put(&no_headers, 56, 0);
    try std.testing.expectEqual(@as(?u64, null), try load_bias(&no_headers, 0, 0));
}
