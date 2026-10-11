const std = @import("std");
const utils = @import("utils.zig");
const Symbol = @import("metadata.zig").Symbol;
const RelocIterator = @import("relocation.zig").RelocIterator;

pub const Error = utils.Error;
const readInt = utils.readInt;

const EM_BPF = 247;
const SHT_SYMTAB = 2;
const STB_GLOBAL = 1;
const SHT_REL = 9;

pub const Section = struct {
    index: usize,
    /// Offset of this section's name inside the section-name string table.
    name: u32,
    kind: u32,
    offset: usize,
    size: usize,
    /// For a symbol table: the index of its string table.
    link: u32,
    /// For a relocation section: the index of the section it patches.
    info: u32,
};

pub const ELF = struct {
    /// the entire ELF file, represented as raw bytes
    bytes: []const u8,
    /// the byte offset where the section header table starts
    shoff: usize,
    /// the size of each section header in bytes
    shentsize: usize,
    /// the number of section headers
    shnum: usize,
    /// the index of the section containing section names.
    shstrndx: usize,

    pub fn init(bytes: []const u8) Error!ELF {
        if (bytes.len < 64) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
        if (bytes[4] != 2 or bytes[5] != 1) return error.Unsupported; // 64-bit, little endian
        if (try readInt(u16, bytes, 18) != EM_BPF) return error.Unsupported;

        const self = ELF{
            .bytes = bytes,
            .shoff = @intCast(try readInt(u64, bytes, 40)),
            .shentsize = try readInt(u16, bytes, 58),
            .shnum = try readInt(u16, bytes, 60),
            .shstrndx = try readInt(u16, bytes, 62),
        };
        if (self.shentsize < 64 or self.shstrndx >= self.shnum) return error.Unsupported;

        // The whole section header table must lie inside the file, so sectionAt can't overrun.
        const table_size = std.math.mul(usize, self.shnum, self.shentsize) catch return error.Truncated;
        const table_end = std.math.add(usize, self.shoff, table_size) catch return error.Truncated;
        if (table_end > bytes.len) return error.Truncated;
        return self;
    }

    pub fn findSection(self: ELF, name: []const u8) Error!Section {
        const names = try self.readSectionData(try self.sectionAt(self.shstrndx));
        var i: usize = 0;
        while (i < self.shnum) : (i += 1) {
            const section = try self.sectionAt(i);
            if (section.name >= names.len) continue;
            if (std.mem.eql(u8, std.mem.sliceTo(names[section.name..], 0), name)) return section;
        }
        return error.SectionNotFound;
    }

    /// Finds a GLOBAL symbol. Zig also emits a LOCAL twin under a qualified name
    /// (oncpu_kern.counter); matching only globals ignores it.
    pub fn findSymbol(self: ELF, name: []const u8) Error!Symbol {
        var i: usize = 0;
        while (i < self.shnum) : (i += 1) {
            const symtab = try self.sectionAt(i);
            if (symtab.kind != SHT_SYMTAB) continue;
            const symbols = try self.readSectionData(symtab);
            const names = try self.readSectionData(try self.sectionAt(symtab.link));

            // Each Elf64_Sym is 24 bytes: name u32, info u8, other u8, shndx u16, value u64, size u64.
            var off: usize = 0;
            while (off + 24 <= symbols.len) : (off += 24) {
                if (symbols[off + 4] >> 4 != STB_GLOBAL) continue;
                const name_off = try readInt(u32, symbols, off);
                if (name_off >= names.len) continue;
                if (!std.mem.eql(u8, std.mem.sliceTo(names[name_off..], 0), name)) continue;
                return .{
                    .section = try readInt(u16, symbols, off + 6),
                    .value = @intCast(try readInt(u64, symbols, off + 8)),
                    .size = @intCast(try readInt(u64, symbols, off + 16)),
                };
            }
        }
        return error.SymbolNotFound;
    }

    /// read The raw bytes of a section
    pub fn readSectionData(self: ELF, section: Section) Error![]const u8 {
        const end = std.math.add(usize, section.offset, section.size) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        return self.bytes[section.offset..end];
    }

    /// The relocations that patch `program`. Empty if the program refers to nothing.
    pub fn relocationsFor(self: ELF, program: Section) Error!RelocIterator {
        var i: usize = 0;
        while (i < self.shnum) : (i += 1) {
            const rel = try self.sectionAt(i);
            if (rel.kind != SHT_REL or rel.info != program.index) continue;
            return .{
                .entries = try self.readSectionData(rel),
                .symbols = try self.readSectionData(try self.sectionAt(rel.link)),
            };
        }
        return .{ .entries = &.{}, .symbols = &.{} };
    }

    fn sectionAt(self: ELF, index: usize) Error!Section {
        if (index >= self.shnum) return error.SectionNotFound;
        const h = self.shoff + index * self.shentsize;
        return .{
            .index = index,
            .name = try readInt(u32, self.bytes, h),
            .kind = try readInt(u32, self.bytes, h + 4),
            .offset = @intCast(try readInt(u64, self.bytes, h + 24)),
            .size = @intCast(try readInt(u64, self.bytes, h + 32)),
            .link = try readInt(u32, self.bytes, h + 40),
            .info = try readInt(u32, self.bytes, h + 44),
        };
    }
};
