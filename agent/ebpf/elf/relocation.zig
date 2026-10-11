const Symbol = @import("metadata.zig").Symbol;
const utils = @import("utils.zig");

const readInt = utils.readInt;
const Error = utils.Error;

const Relocation = struct {
    /// Byte offset of the instruction to patch, inside the program section.
    offset: usize,
    /// Relocation kind. 1 is R_BPF_64_64: a 64-bit immediate, which is how a map address is loaded.
    kind: u32,
    /// What the instruction refers to, looked up through the symbol table.
    target: Symbol,
};

pub const RelocIterator = struct {
    entries: []const u8, // Elf64_Rel, 16 bytes each: offset u64, info u64
    symbols: []const u8, // the symbol table, 24 bytes per symbol
    pos: usize = 0,

    pub fn next(self: *RelocIterator) Error!?Relocation {
        if (self.pos + 16 > self.entries.len) return null;
        const offset = try readInt(u64, self.entries, self.pos);
        const info = try readInt(u64, self.entries, self.pos + 8);
        self.pos += 16;

        // The high half of `info` is the symbol index, the low half is the kind.
        const sym: usize = @intCast(info >> 32);
        const at = sym * 24;
        return .{
            .offset = @intCast(offset),
            .kind = @truncate(info),
            .target = .{
                .section = try readInt(u16, self.symbols, at + 6),
                .value = @intCast(try readInt(u64, self.symbols, at + 8)),
                .size = @intCast(try readInt(u64, self.symbols, at + 16)),
            },
        };
    }
};
