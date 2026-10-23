//! A minimal reader for 64-bit little-endian ELF files, working on bytes already in memory.
//! It grows step by step into what symbolization needs. For now it reads the header and the
//! program headers, which say where each piece of the file is loaded.
const std = @import("std");

pub const Error = error{ NotElf, Truncated, Unsupported };

const ehdr_size = 64;
const phdr_size = 56;
const PT_LOAD = 1;
const PT_NOTE = 4;
const NT_GNU_BUILD_ID = 3;

/// A phnum of 0xffff means "the real count is stored elsewhere"; no normal binary does that.
const PN_XNUM = 0xffff;
const shdr_size = 64;
const sym_size = 24;
const SHT_SYMTAB = 2;
const SHT_STRTAB = 3;
const SHT_DYNSYM = 11;
const STT_FUNC = 2;
const STT_GNU_IFUNC = 10;
const SHN_UNDEF = 0;

pub const Symbol = struct {
    /// Points into the file's string table.
    name: []const u8,
    /// The symbol's virtual address, in the same address space as `Elf.vaddrOf`.
    value: u64,
    size: u64,
};

pub const Table = enum { symtab, dynsym };

/// Yields the defined function symbols of one table, in file order. Imports (undefined
/// symbols), data symbols, and entries whose name cannot be read are skipped.
pub const SymbolIterator = struct {
    entries: []const u8,
    strings: []const u8,
    next_index: usize = 0,

    pub fn next(self: *SymbolIterator) ?Symbol {
        while ((self.next_index + 1) * sym_size <= self.entries.len) {
            const base = self.next_index * sym_size;
            self.next_index += 1;

            const kind = self.entries[base + 4] & 0xf; // the low 4 bits of st_info
            if (kind != STT_FUNC and kind != STT_GNU_IFUNC) continue;

            const shndx = readU16(self.entries, base + 6);
            const value = readU64(self.entries, base + 8);
            if (shndx == SHN_UNDEF or value == 0) continue;

            const name = cString(self.strings, readU32(self.entries, base)) orelse continue;
            if (name.len == 0) continue;

            return .{ .name = name, .value = value, .size = readU64(self.entries, base + 16) };
        }
        return null;
    }
};

const Section = struct {
    kind: u32,
    offset: u64,
    size: u64,
    link: u32,
};

pub const Elf = struct {
    bytes: []const u8,
    phoff: u64,
    phnum: u16,
    shoff: u64,
    shnum: u16,

    pub fn parse(bytes: []const u8) Error!Elf {
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
        if (bytes.len < ehdr_size) return error.Truncated;
        // Only 64-bit (class 2), little-endian (data 1) files: that is all of x86-64 Linux.
        if (bytes[4] != 2 or bytes[5] != 1) return error.Unsupported;

        const phoff = readU64(bytes, 32);
        const phentsize = readU16(bytes, 54);
        const phnum = readU16(bytes, 56);
        if (phnum == PN_XNUM) return error.Unsupported;

        if (phnum > 0) {
            if (phentsize != phdr_size) return error.Unsupported;
            const table = std.math.mul(u64, phnum, phdr_size) catch return error.Truncated;
            const end = std.math.add(u64, phoff, table) catch return error.Truncated;
            if (end > bytes.len) return error.Truncated;
        }
        // The section table is optional: a file can be stripped of it. When present it
        // must lie inside the file.
        const shoff = readU64(bytes, 40);
        const shentsize = readU16(bytes, 58);
        const shnum = readU16(bytes, 60);
        if (shnum > 0) {
            if (shentsize != shdr_size) return error.Unsupported;
            const table = std.math.mul(u64, shnum, shdr_size) catch return error.Truncated;
            const end = std.math.add(u64, shoff, table) catch return error.Truncated;
            if (end > bytes.len) return error.Truncated;
        }

        return .{ .bytes = bytes, .phoff = phoff, .phnum = phnum, .shoff = shoff, .shnum = shnum };
    }

    /// The virtual address the ELF assigns to the byte at `file_offset`, found through the
    /// PT_LOAD segment that contains it. Null if no loadable segment holds that byte.
    /// Symbol addresses in an ELF are virtual addresses, and for position-independent
    /// binaries and libraries they are relative to the load base, so this is the number
    /// to look symbols up with.
    pub fn vaddrOf(self: Elf, file_offset: u64) ?u64 {
        var i: u64 = 0;
        while (i < self.phnum) : (i += 1) {
            const base: usize = @intCast(self.phoff + i * phdr_size);
            if (readU32(self.bytes, base) != PT_LOAD) continue;

            const offset = readU64(self.bytes, base + 8);
            const vaddr = readU64(self.bytes, base + 16);
            const filesz = readU64(self.bytes, base + 32);

            // The end of the segment is exclusive.
            if (file_offset >= offset and file_offset - offset < filesz) {
                return std.math.add(u64, vaddr, file_offset - offset) catch null;
            }
        }
        return null;
    }

    /// The inverse of `vaddrOf`: where in the file the byte at virtual address `vaddr` is stored.
    /// Null if no loadable segment holds that address.
    pub fn fileOffsetOf(self: Elf, vaddr: u64) ?u64 {
        var i: u64 = 0;
        while (i < self.phnum) : (i += 1) {
            const base: usize = @intCast(self.phoff + i * phdr_size);
            if (readU32(self.bytes, base) != PT_LOAD) continue;

            const offset = readU64(self.bytes, base + 8);
            const segment_vaddr = readU64(self.bytes, base + 16);
            const filesz = readU64(self.bytes, base + 32);

            if (vaddr >= segment_vaddr and vaddr - segment_vaddr < filesz) {
                return std.math.add(u64, offset, vaddr - segment_vaddr) catch null;
            }
        }
        return null;
    }

    /// The GNU build ID of the file: its unique fingerprint, which is what the agent reports
    /// for each region. Points into the file's bytes. Null if the file has none.
    pub fn buildId(self: Elf) ?[]const u8 {
        var i: u64 = 0;
        while (i < self.phnum) : (i += 1) {
            const base: usize = @intCast(self.phoff + i * phdr_size);
            if (readU32(self.bytes, base) != PT_NOTE) continue;

            const offset = readU64(self.bytes, base + 8);
            const filesz = readU64(self.bytes, base + 32);
            const end = std.math.add(u64, offset, filesz) catch continue;
            if (end > self.bytes.len) continue; // a segment outside the file is ignored

            if (findBuildId(self.bytes[@intCast(offset)..@intCast(end)])) |id| return id;
        }
        return null;
    }

    /// The function symbols of `table`. A file without that table gives an empty iterator.
    /// A table that points outside the file is `error.Truncated`.
    pub fn symbols(self: Elf, table: Table) Error!SymbolIterator {
        const wanted: u32 = switch (table) {
            .symtab => SHT_SYMTAB,
            .dynsym => SHT_DYNSYM,
        };
        var i: u64 = 0;
        while (i < self.shnum) : (i += 1) {
            const section = self.sectionAt(i).?;
            if (section.kind != wanted) continue;

            const entries = self.contents(section) orelse return error.Truncated;
            // sh_link of a symbol table is the index of its string table.
            const link = self.sectionAt(section.link) orelse return error.Truncated;
            const strings = self.contents(link) orelse return error.Truncated;
            return .{ .entries = entries, .strings = strings };
        }
        return .{ .entries = &.{}, .strings = &.{} };
    }

    fn sectionAt(self: Elf, index: u64) ?Section {
        if (index >= self.shnum) return null;
        // parse() checked that the whole table lies inside the file.
        const base: usize = @intCast(self.shoff + index * shdr_size);
        return .{
            .kind = readU32(self.bytes, base + 4),
            .offset = readU64(self.bytes, base + 24),
            .size = readU64(self.bytes, base + 32),
            .link = readU32(self.bytes, base + 40),
        };
    }

    fn contents(self: Elf, section: Section) ?[]const u8 {
        const end = std.math.add(u64, section.offset, section.size) catch return null;
        if (end > self.bytes.len) return null;
        return self.bytes[@intCast(section.offset)..@intCast(end)];
    }
};

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

/// The NUL-terminated string at `offset`, or null if it starts outside `strings` or has no end.
fn cString(strings: []const u8, offset: u32) ?[]const u8 {
    if (offset >= strings.len) return null;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    return rest[0..end];
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn align4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

/// Walks a sequence of ELF notes and returns the descriptor of the GNU build ID note.
/// Every size comes from the file, so nothing is trusted.
fn findBuildId(notes: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (notes.len - at >= 12) {
        const namesz: usize = readU32(notes, at);
        const descsz: usize = readU32(notes, at + 4);
        const kind = readU32(notes, at + 8);

        // On a 64-bit machine, 32-bit sizes plus padding cannot overflow usize.
        const name_at = at + 12;
        const desc_at = name_at + align4(namesz);
        if (desc_at > notes.len or descsz > notes.len - desc_at) return null;

        if (kind == NT_GNU_BUILD_ID and namesz == 4 and
            std.mem.eql(u8, notes[name_at..][0..4], "GNU\x00") and
            descsz >= 1 and descsz <= 64)
        {
            return notes[desc_at..][0..descsz];
        }

        const next = desc_at + align4(descsz);
        if (next > notes.len) return null;
        at = next;
    }
    return null;
}

// ------------------------------------------------------------------ tests

fn put16(buf: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], value, .little);
}

fn put32(buf: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], value, .little);
}

fn put64(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

fn setPhdr(buf: []u8, index: usize, p_type: u32, offset: u64, vaddr: u64, filesz: u64) void {
    const base = ehdr_size + index * phdr_size;
    put32(buf, base, p_type);
    put32(buf, base + 4, 5); // flags: readable and executable
    put64(buf, base + 8, offset);
    put64(buf, base + 16, vaddr);
    put64(buf, base + 24, vaddr); // physical address, unused
    put64(buf, base + 32, filesz);
    put64(buf, base + 40, filesz); // size in memory
    put64(buf, base + 48, 0x1000);
}

const test_size = ehdr_size + 4 * phdr_size;

/// A file with a 64-bit header and four program headers:
///   0: LOAD  offset 0x0    vaddr 0x400000  size 0x1000
///   1: LOAD  offset 0x1000 vaddr 0x401000  size 0x2000
///   2: NOTE  offset 0x3000 vaddr 0x403000  size 0x100   (not loadable)
///   3: LOAD  offset 0x3e00 vaddr 0x404e00  size 0x200   (a vaddr that is not the offset + base)
fn testFile(buf: *[test_size]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // 64-bit
    buf[5] = 1; // little-endian
    buf[6] = 1; // version
    put16(buf, 16, 3); // a shared object or PIE
    put16(buf, 18, 62); // x86-64
    put32(buf, 20, 1);
    put64(buf, 32, ehdr_size); // where the program headers start
    put16(buf, 52, ehdr_size);
    put16(buf, 54, phdr_size);
    put16(buf, 56, 4); // how many program headers

    setPhdr(buf, 0, PT_LOAD, 0x0, 0x400000, 0x1000);
    setPhdr(buf, 1, PT_LOAD, 0x1000, 0x401000, 0x2000);
    setPhdr(buf, 2, 4, 0x3000, 0x403000, 0x100);
    setPhdr(buf, 3, PT_LOAD, 0x3e00, 0x404e00, 0x200);
}

test "vaddrOf turns a file offset into the ELF's virtual address" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);
    const elf = try Elf.parse(&buf);

    try std.testing.expectEqual(@as(?u64, 0x401234), elf.vaddrOf(0x1234));
    try std.testing.expectEqual(@as(?u64, 0x404e10), elf.vaddrOf(0x3e10)); // vaddr differs from offset by more than the base
}

test "vaddrOf: segment starts are included, ends are not" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);
    const elf = try Elf.parse(&buf);

    try std.testing.expectEqual(@as(?u64, 0x400000), elf.vaddrOf(0x0));
    try std.testing.expectEqual(@as(?u64, 0x400fff), elf.vaddrOf(0xfff));
    try std.testing.expectEqual(@as(?u64, 0x401000), elf.vaddrOf(0x1000)); // next segment starts here
    try std.testing.expectEqual(@as(?u64, 0x402fff), elf.vaddrOf(0x2fff));
    try std.testing.expectEqual(@as(?u64, null), elf.vaddrOf(0x3000)); // end of segment 1, and only a NOTE lives here
    try std.testing.expectEqual(@as(?u64, 0x404fff), elf.vaddrOf(0x3fff));
    try std.testing.expectEqual(@as(?u64, null), elf.vaddrOf(0x4000));
}

test "vaddrOf: offsets that no loadable segment holds give null" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);
    const elf = try Elf.parse(&buf);

    try std.testing.expectEqual(@as(?u64, null), elf.vaddrOf(0x3010)); // inside the NOTE only
    try std.testing.expectEqual(@as(?u64, null), elf.vaddrOf(0x3dff)); // the gap before the last segment
    try std.testing.expectEqual(@as(?u64, null), elf.vaddrOf(std.math.maxInt(u64)));
}

test "parse rejects what is not a usable ELF file" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);

    try std.testing.expectError(error.NotElf, Elf.parse(""));
    try std.testing.expectError(error.NotElf, Elf.parse("this is not an elf file at all, it is text"));
    try std.testing.expectError(error.Truncated, Elf.parse(buf[0..10])); // magic, then nothing
    try std.testing.expectError(error.Truncated, Elf.parse(buf[0..100])); // program headers cut off

    var thirty_two_bit = buf;
    thirty_two_bit[4] = 1;
    try std.testing.expectError(error.Unsupported, Elf.parse(&thirty_two_bit));

    var big_endian = buf;
    big_endian[5] = 2;
    try std.testing.expectError(error.Unsupported, Elf.parse(&big_endian));

    var many = buf;
    put16(&many, 56, 0xffff);
    try std.testing.expectError(error.Unsupported, Elf.parse(&many));

    var absurd_offset = buf;
    put64(&absurd_offset, 32, std.math.maxInt(u64) - 8); // the table would run past the end of the file
    try std.testing.expectError(error.Truncated, Elf.parse(&absurd_offset));
}

fn setShdr(buf: []u8, index: usize, kind: u32, offset: u64, size: u64, link: u32) void {
    const base = ehdr_size + index * shdr_size; // the section table sits right after the header
    put32(buf, base + 4, kind);
    put64(buf, base + 24, offset);
    put64(buf, base + 32, size);
    put32(buf, base + 40, link);
}

fn setSym(buf: []u8, index: usize, name: u32, info: u8, shndx: u16, value: u64, size: u64) void {
    const base = 256 + index * sym_size;
    put32(buf, base, name);
    buf[base + 4] = info;
    put16(buf, base + 6, shndx);
    put64(buf, base + 8, value);
    put64(buf, base + 16, size);
}

pub const sym_file_size = 448;

/// A file with 3 sections: 0 is empty, 1 is a .symtab at offset 256 with 7 symbols, 2 is its
/// string table at offset 424. The strings are: "" at 0, "main" at 1, "helper" at 6,
/// "data" at 13, "ifunc" at 18.
pub fn symFile(buf: *[sym_file_size]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    buf[6] = 1;
    put16(buf, 16, 3);
    put16(buf, 18, 62);
    put32(buf, 20, 1);
    put64(buf, 40, ehdr_size); // where the section headers start
    put16(buf, 52, ehdr_size);
    put16(buf, 58, shdr_size);
    put16(buf, 60, 3); // how many sections

    setShdr(buf, 0, 0, 0, 0, 0);
    setShdr(buf, 1, SHT_SYMTAB, 256, 7 * sym_size, 2);
    setShdr(buf, 2, SHT_STRTAB, 424, 24, 0);

    setSym(buf, 0, 0, 0x00, 0, 0, 0); // the mandatory empty first entry
    setSym(buf, 1, 1, 0x12, 1, 0x1130, 0x40); // global function "main"
    setSym(buf, 2, 6, 0x02, 1, 0x1170, 0x20); // local function "helper"
    setSym(buf, 3, 13, 0x11, 2, 0x4000, 8); // a data object: skipped
    setSym(buf, 4, 18, 0x1a, 1, 0x1190, 0x10); // an indirect function "ifunc"
    setSym(buf, 5, 6, 0x12, 0, 0, 0); // an import (undefined): skipped
    setSym(buf, 6, 500, 0x12, 1, 0x11a0, 0x10); // the name lies outside the table: skipped

    @memcpy(buf[424..][0..24], "\x00main\x00helper\x00data\x00ifunc\x00");
}

test "symbols lists the defined functions with their addresses and sizes" {
    var buf: [sym_file_size]u8 = undefined;
    symFile(&buf);
    const elf = try Elf.parse(&buf);

    var it = try elf.symbols(.symtab);

    const main = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", main.name);
    try std.testing.expectEqual(@as(u64, 0x1130), main.value);
    try std.testing.expectEqual(@as(u64, 0x40), main.size);

    const helper = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("helper", helper.name);
    try std.testing.expectEqual(@as(u64, 0x1170), helper.value);
    try std.testing.expectEqual(@as(u64, 0x20), helper.size);

    const ifunc = it.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ifunc", ifunc.name);
    try std.testing.expectEqual(@as(u64, 0x1190), ifunc.value);

    try std.testing.expect(it.next() == null);
}

test "symbols: a table the file does not have gives nothing" {
    var buf: [sym_file_size]u8 = undefined;
    symFile(&buf);
    const elf = try Elf.parse(&buf);

    var dynsym = try elf.symbols(.dynsym); // this file only has a .symtab
    try std.testing.expect(dynsym.next() == null);

    var plain: [test_size]u8 = undefined;
    testFile(&plain); // program headers only, no sections at all
    const stripped = try Elf.parse(&plain);
    var symtab = try stripped.symbols(.symtab);
    try std.testing.expect(symtab.next() == null);
}

test "symbols and parse reject tables that point outside the file" {
    var buf: [sym_file_size]u8 = undefined;
    symFile(&buf);

    var bad_link = buf;
    setShdr(&bad_link, 1, SHT_SYMTAB, 256, 7 * sym_size, 9); // no section 9
    const a = try Elf.parse(&bad_link);
    try std.testing.expectError(error.Truncated, a.symbols(.symtab));

    var bad_data = buf;
    setShdr(&bad_data, 1, SHT_SYMTAB, 400, 7 * sym_size, 2); // runs past the end of the file
    const b = try Elf.parse(&bad_data);
    try std.testing.expectError(error.Truncated, b.symbols(.symtab));

    var bad_table = buf;
    put64(&bad_table, 40, 1000); // the section headers would start past the end
    try std.testing.expectError(error.Truncated, Elf.parse(&bad_table));
}

/// Writes one note at `at` and returns where the next one starts.
fn putNote(buf: []u8, at: usize, name: []const u8, kind: u32, desc: []const u8) usize {
    put32(buf, at, @intCast(name.len + 1)); // the name's size includes its NUL
    put32(buf, at + 4, @intCast(desc.len));
    put32(buf, at + 8, kind);
    const name_at = at + 12;
    @memcpy(buf[name_at..][0..name.len], name);
    buf[name_at + name.len] = 0;
    const desc_at = name_at + align4(name.len + 1);
    @memcpy(buf[desc_at..][0..desc.len], desc);
    return desc_at + align4(desc.len);
}

/// A header with one NOTE program header whose segment is the notes at offset 128.
fn noteHeader(buf: []u8, notes_len: u64) void {
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    put64(buf, 32, ehdr_size);
    put16(buf, 54, phdr_size);
    put16(buf, 56, 1);
    setPhdr(buf, 0, PT_NOTE, 128, 0x200, notes_len);
}

const test_id = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

test "buildId finds the GNU note, also after another note" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    var end = putNote(&buf, 128, "Xyz", 1, "abcd");
    end = putNote(&buf, end, "GNU", NT_GNU_BUILD_ID, &test_id);
    noteHeader(&buf, end - 128);

    const file = try Elf.parse(buf[0..end]);
    const id = file.buildId() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &test_id, id);
}

test "buildId: notes that are not a GNU build ID give null" {
    var buf: [256]u8 = undefined;

    // Right type, wrong owner.
    @memset(&buf, 0);
    var end = putNote(&buf, 128, "Xyz", NT_GNU_BUILD_ID, &test_id);
    noteHeader(&buf, end - 128);
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);

    // Right owner, wrong type.
    @memset(&buf, 0);
    end = putNote(&buf, 128, "GNU", 1, &test_id);
    noteHeader(&buf, end - 128);
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);

    // An empty descriptor is no fingerprint.
    @memset(&buf, 0);
    end = putNote(&buf, 128, "GNU", NT_GNU_BUILD_ID, &.{});
    noteHeader(&buf, end - 128);
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);

    // A name that is not exactly "GNU" plus its NUL.
    @memset(&buf, 0);
    end = putNote(&buf, 128, "GNUU", NT_GNU_BUILD_ID, &test_id);
    noteHeader(&buf, end - 128);
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);
}

test "buildId: sizes that run past the segment give null instead of reading out of bounds" {
    var buf: [256]u8 = undefined;
    @memset(&buf, 0);
    var end = putNote(&buf, 128, "GNU", NT_GNU_BUILD_ID, &test_id);
    noteHeader(&buf, end - 128);

    put32(&buf, 128 + 4, 1000); // the descriptor claims to be 1000 bytes
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);

    put32(&buf, 128 + 4, 20);
    put32(&buf, 128, 0xffffffff); // the name claims to be 4 GiB
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);

    put32(&buf, 128, 4);
    end -= 10; // the segment itself is now cut inside the descriptor
    noteHeader(&buf, end - 128);
    try std.testing.expect((try Elf.parse(buf[0..end])).buildId() == null);
}

test "buildId: a NOTE segment outside the file is ignored, and a file without notes has no id" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf); // its NOTE header points at offset 0x3000, far past the end of the file
    const file = try Elf.parse(&buf);
    try std.testing.expect(file.buildId() == null);
}

test "fileOffsetOf is the inverse of vaddrOf" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);
    const elf = try Elf.parse(&buf);

    try std.testing.expectEqual(@as(?u64, 0x1234), elf.fileOffsetOf(0x401234));
    try std.testing.expectEqual(@as(?u64, 0x3e10), elf.fileOffsetOf(0x404e10));
    try std.testing.expectEqual(@as(?u64, 0), elf.fileOffsetOf(0x400000));
    try std.testing.expectEqual(@as(?u64, 0xfff), elf.fileOffsetOf(0x400fff));
    try std.testing.expectEqual(@as(?u64, 0x3fff), elf.fileOffsetOf(0x404fff));
    try std.testing.expectEqual(@as(?u64, null), elf.fileOffsetOf(0x403000)); // only a NOTE lives here
    try std.testing.expectEqual(@as(?u64, null), elf.fileOffsetOf(0x405000));
    try std.testing.expectEqual(@as(?u64, null), elf.fileOffsetOf(0x3fffff));
    try std.testing.expectEqual(@as(?u64, null), elf.fileOffsetOf(std.math.maxInt(u64)));
}

test "going to a virtual address and back gives the same file offset" {
    var buf: [test_size]u8 = undefined;
    testFile(&buf);
    const elf = try Elf.parse(&buf);

    for ([_]u64{ 0, 0xfff, 0x1000, 0x2fff, 0x3e00, 0x3fff }) |offset| {
        const vaddr = elf.vaddrOf(offset) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?u64, offset), elf.fileOffsetOf(vaddr));
    }
}
