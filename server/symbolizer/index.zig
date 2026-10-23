//! Finds the function that contains an address. Built once per binary from its symbol table.
const std = @import("std");
const elf = @import("elf.zig");

const Entry = struct {
    value: u64,
    size: u64,
    name: []const u8,
    /// Position in the symbol table, so ties are broken the same way every time.
    order: usize,
};

pub const Match = struct {
    name: []const u8,
    /// How far into the function the address is.
    offset: u64,
};

pub const Index = struct {
    /// Sorted by address, one entry per address. Names point into the file the symbols were
    /// read from, so that file's bytes must outlive the index.
    entries: []const Entry,

    /// The index of a file's function symbols: its `.symtab`, or its `.dynsym` when the
    /// file has no `.symtab` (or it holds no functions), which is the case for stripped files.
    pub fn build(allocator: std.mem.Allocator, file: elf.Elf) !Index {
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(allocator);

        var symtab = try file.symbols(.symtab);
        try collect(allocator, &list, &symtab);
        if (list.items.len == 0) {
            var dynsym = try file.symbols(.dynsym);
            try collect(allocator, &list, &dynsym);
        }
        return finish(allocator, &list);
    }

    /// The same, from symbols you already have. Mostly for tests.
    pub fn fromSymbols(allocator: std.mem.Allocator, symbols: []const elf.Symbol) !Index {
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(allocator);

        for (symbols) |symbol| {
            try list.append(allocator, .{
                .value = symbol.value,
                .size = symbol.size,
                .name = symbol.name,
                .order = list.items.len,
            });
        }
        return finish(allocator, &list);
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    /// The function that contains `vaddr`, or null if there is none.
    pub fn lookup(self: Index, vaddr: u64) ?Match {
        // Binary search for the number of entries whose address is at or below `vaddr`.
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].value <= vaddr) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;

        const i = lo - 1;
        const entry = self.entries[i];
        const offset = vaddr - entry.value;

        if (entry.size > 0) {
            if (offset >= entry.size) return null;
        } else if (i + 1 < self.entries.len) {
            // No size: it reaches up to the next symbol, which starts above `vaddr`.
        } else if (offset != 0) {
            return null;
        }
        return .{ .name = entry.name, .offset = offset };
    }
};

fn collect(allocator: std.mem.Allocator, list: *std.ArrayList(Entry), it: *elf.SymbolIterator) !void {
    while (it.next()) |symbol| {
        try list.append(allocator, .{
            .value = symbol.value,
            .size = symbol.size,
            .name = symbol.name,
            .order = list.items.len,
        });
    }
}

/// Sorts by address, keeps the best name for each address, and returns the finished index.
fn finish(allocator: std.mem.Allocator, list: *std.ArrayList(Entry)) !Index {
    std.mem.sort(Entry, list.items, {}, lessThan);

    // Within one address the best name comes first, so keep the first and drop the rest.
    var kept: usize = 0;
    for (list.items) |entry| {
        if (kept > 0 and list.items[kept - 1].value == entry.value) continue;
        list.items[kept] = entry;
        kept += 1;
    }
    list.items.len = kept;

    return .{ .entries = try list.toOwnedSlice(allocator) };
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.value != b.value) return a.value < b.value;
    const underscores_a = leadingUnderscores(a.name);
    const underscores_b = leadingUnderscores(b.name);
    if (underscores_a != underscores_b) return underscores_a < underscores_b;
    return a.order < b.order;
}

fn leadingUnderscores(name: []const u8) usize {
    var n: usize = 0;
    while (n < name.len and name[n] == '_') n += 1;
    return n;
}

// ------------------------------------------------------------------ tests

test "build: finds functions in an ELF file and skips what is not a function" {
    var buf: [elf.sym_file_size]u8 = undefined;
    elf.symFile(&buf);
    const file = try elf.Elf.parse(&buf);

    var index = try Index.build(std.testing.allocator, file);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), index.entries.len); // main, helper, ifunc

    const first = index.lookup(0x1130) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", first.name);
    try std.testing.expectEqual(@as(u64, 0), first.offset);

    const inside = index.lookup(0x116f) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", inside.name);
    try std.testing.expectEqual(@as(u64, 0x3f), inside.offset);

    const second = index.lookup(0x1170) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("helper", second.name);
    try std.testing.expectEqual(@as(u64, 0), second.offset);

    const last = index.lookup(0x119f) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ifunc", last.name);
    try std.testing.expectEqual(@as(u64, 0xf), last.offset);

    try std.testing.expect(index.lookup(0x112f) == null); // just below the first function
    try std.testing.expect(index.lookup(0x11a0) == null); // just past the last one
    try std.testing.expect(index.lookup(0x4000) == null); // where a data symbol lives
}

test "build: a file with only .dynsym is indexed from it" {
    var buf: [elf.sym_file_size]u8 = undefined;
    elf.symFile(&buf);
    // Section 1 starts at byte 128 (header 64 + one 64-byte section header), and its type
    // is 4 bytes in. 11 is SHT_DYNSYM, so the symbol table now looks like a dynamic one.
    std.mem.writeInt(u32, buf[132..][0..4], 11, .little);
    const file = try elf.Elf.parse(&buf);

    var index = try Index.build(std.testing.allocator, file);
    defer index.deinit(std.testing.allocator);

    const found = index.lookup(0x1140) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", found.name);
    try std.testing.expectEqual(@as(u64, 0x10), found.offset);
}

test "lookup: input order does not matter, ends are exclusive, gaps give nothing" {
    const symbols = [_]elf.Symbol{
        .{ .name = "c", .value = 0x3000, .size = 0x10 },
        .{ .name = "a", .value = 0x1000, .size = 0x100 },
        .{ .name = "b", .value = 0x2000, .size = 0x10 },
    };
    var index = try Index.fromSymbols(std.testing.allocator, &symbols);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a", index.lookup(0x1000).?.name);
    try std.testing.expectEqual(@as(u64, 0xff), index.lookup(0x10ff).?.offset);
    try std.testing.expect(index.lookup(0x1100) == null); // the end of "a" is exclusive
    try std.testing.expect(index.lookup(0x1fff) == null); // inside the gap
    try std.testing.expectEqualStrings("b", index.lookup(0x2008).?.name);
    try std.testing.expectEqualStrings("b", index.lookup(0x200f).?.name);
    try std.testing.expect(index.lookup(0x2010) == null);
    try std.testing.expectEqualStrings("c", index.lookup(0x3000).?.name);
    try std.testing.expect(index.lookup(0x3010) == null);
    try std.testing.expect(index.lookup(0xfff) == null); // below everything
    try std.testing.expect(index.lookup(std.math.maxInt(u64)) == null);
}

test "lookup: a symbol without a size reaches the next symbol, the last one only matches exactly" {
    const symbols = [_]elf.Symbol{
        .{ .name = "start", .value = 0x1000, .size = 0 },
        .{ .name = "next", .value = 0x1040, .size = 0x10 },
        .{ .name = "tail", .value = 0x2000, .size = 0 },
    };
    var index = try Index.fromSymbols(std.testing.allocator, &symbols);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0x20), index.lookup(0x1020).?.offset);
    try std.testing.expectEqualStrings("start", index.lookup(0x103f).?.name);
    try std.testing.expectEqualStrings("next", index.lookup(0x1040).?.name);
    try std.testing.expect(index.lookup(0x1050) == null); // "next" has a size, so it stops there
    try std.testing.expectEqualStrings("tail", index.lookup(0x2000).?.name);
    try std.testing.expect(index.lookup(0x2001) == null);
}

test "aliases: fewer leading underscores wins, then the first in the table" {
    const symbols = [_]elf.Symbol{
        .{ .name = "__write", .value = 0x1000, .size = 0x20 },
        .{ .name = "write", .value = 0x1000, .size = 0x20 },
        .{ .name = "__libc_write", .value = 0x1000, .size = 0x20 },
        .{ .name = "beta", .value = 0x2000, .size = 0x20 },
        .{ .name = "alpha", .value = 0x2000, .size = 0x20 },
    };
    var index = try Index.fromSymbols(std.testing.allocator, &symbols);
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), index.entries.len); // one per address
    try std.testing.expectEqualStrings("write", index.lookup(0x1010).?.name);
    try std.testing.expectEqualStrings("beta", index.lookup(0x2000).?.name); // tie: first in the table
}

test "an empty index finds nothing" {
    var index = try Index.fromSymbols(std.testing.allocator, &.{});
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), index.entries.len);
    try std.testing.expect(index.lookup(0x1000) == null);
    try std.testing.expect(index.lookup(0) == null);
}
