//! The functions of one binary.

const std = @import("std");
const elf = @import("shared").elf;

const assert = std.debug.assert;

const sym_bytes = 24;
const stt_func = 2;
const stt_gnu_ifunc = 10;
const name_bytes_max = 4096;

pub const Error = error{ OutOfMemory, TooLarge };

pub const Input = struct {
    segments: []const elf.Segment,
    symtab: []const u8 = &.{},
    strtab: []const u8 = &.{},
    dynsym: []const u8 = &.{},
    dynstr: []const u8 = &.{},
};

pub const Hit = struct {
    name: []const u8,
    inside: u64,
};

const Entry = struct {
    start: u64,
    name: u32,
    size: u32,
};

pub const SymbolTable = struct {
    entries: []Entry,
    count: usize,
    names: []u8,

    pub fn init(gpa: std.mem.Allocator, input: Input) Error!SymbolTable {
        const syms, const strs = if (input.symtab.len > 0)
            .{ input.symtab, input.strtab }
        else
            .{ input.dynsym, input.dynstr };
        const symbols_count = syms.len / sym_bytes;

        var count: usize = 0;
        var names_total: usize = 0;
        for (0..symbols_count) |index| {
            const raw = sym_read(input.segments, syms, strs, index) orelse continue;
            count += 1;
            names_total += raw.name.len + 1;
        }
        if (names_total > std.math.maxInt(u32)) return error.TooLarge;

        const entries = try gpa.alloc(Entry, count);
        errdefer gpa.free(entries);
        const names = try gpa.alloc(u8, names_total);
        errdefer gpa.free(names);

        var filled: usize = 0;
        var names_at: usize = 0;
        for (0..symbols_count) |index| {
            const raw = sym_read(input.segments, syms, strs, index) orelse continue;
            @memcpy(names[names_at..][0..raw.name.len], raw.name);
            names[names_at + raw.name.len] = 0;
            entries[filled] = .{
                .start = raw.start,
                .name = @intCast(names_at),
                .size = @intCast(@min(raw.size, std.math.maxInt(u32))),
            };
            filled += 1;
            names_at += raw.name.len + 1;
        }
        assert(filled == count and names_at == names_total);
        std.mem.sortUnstable(Entry, entries, {}, entry_less);
        const kept = aliases_drop(entries);
        sizes_fill(entries[0..kept]);
        return .{ .entries = entries, .count = kept, .names = names };
    }

    pub fn deinit(table: *SymbolTable, gpa: std.mem.Allocator) void {
        gpa.free(table.entries);
        gpa.free(table.names);
        table.* = undefined;
    }

    pub fn bytes(table: *const SymbolTable) u64 {
        return table.entries.len * @sizeOf(Entry) + table.names.len;
    }

    pub fn lookup(table: *const SymbolTable, offset: u64) ?Hit {
        const entries = table.entries[0..table.count];
        var low: usize = 0;
        var high: usize = entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (entries[middle].start <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == 0) return null;

        const entry = entries[low - 1];
        const inside = offset - entry.start;
        if (inside >= entry.size) return null;
        return .{ .name = std.mem.sliceTo(table.names[entry.name..], 0), .inside = inside };
    }
};

const Raw = struct {
    name: []const u8,
    start: u64,
    size: u64,
};

fn sym_read(segments: []const elf.Segment, syms: []const u8, strs: []const u8, index: usize) ?Raw {
    const at = index * sym_bytes;
    assert(at + sym_bytes <= syms.len);

    const name_at = std.mem.readInt(u32, syms[at..][0..4], .little);
    const info = syms[at + 4];
    const section_index = std.mem.readInt(u16, syms[at + 6 ..][0..2], .little);
    const value = std.mem.readInt(u64, syms[at + 8 ..][0..8], .little);
    const size = std.mem.readInt(u64, syms[at + 16 ..][0..8], .little);

    const kind = info & 0xf;
    if (kind != stt_func and kind != stt_gnu_ifunc) return null;
    if (section_index == 0) return null;
    const start = file_offset(segments, value) orelse return null;

    if (name_at >= strs.len) return null;
    const rest = strs[name_at..];
    const length = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    if (length == 0) return null;
    return .{ .name = rest[0..@min(length, name_bytes_max)], .start = start, .size = size };
}

fn file_offset(segments: []const elf.Segment, address: u64) ?u64 {
    for (segments) |segment| {
        if (address < segment.vaddr) continue;
        const inside = address - segment.vaddr;
        if (inside >= segment.filesz) continue;
        return std.math.add(u64, segment.offset, inside) catch return null;
    }
    return null;
}

fn entry_less(_: void, a: Entry, b: Entry) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.name < b.name;
}

fn aliases_drop(entries: []Entry) usize {
    var kept: usize = 0;
    for (entries) |entry| {
        if (kept > 0 and entries[kept - 1].start == entry.start) continue;
        entries[kept] = entry;
        kept += 1;
    }
    return kept;
}

fn sizes_fill(entries: []Entry) void {
    for (entries, 0..) |*entry, index| {
        if (entry.size != 0) continue;
        const size = if (index + 1 < entries.len) entries[index + 1].start - entry.start else 1;
        entry.size = @intCast(@min(size, std.math.maxInt(u32)));
    }
}

const testing = std.testing;

fn sym_write(
    out: []u8,
    index: usize,
    name: u32,
    info: u8,
    section_index: u16,
    value: u64,
    size: u64,
) void {
    const at = index * sym_bytes;
    std.mem.writeInt(u32, out[at..][0..4], name, .little);
    out[at + 4] = info;
    out[at + 5] = 0;
    std.mem.writeInt(u16, out[at + 6 ..][0..2], section_index, .little);
    std.mem.writeInt(u64, out[at + 8 ..][0..8], value, .little);
    std.mem.writeInt(u64, out[at + 16 ..][0..8], size, .little);
}

const strs_test = "\x00main\x00helper\x00data\x00start\x00alias\x00";
const name_main = 1;
const name_helper = 6;
const name_data = 13;
const name_start = 18;
const name_alias = 24;

const segments_test = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x2000 }};

test "a lookup finds the function that contains the offset, in file offsets" {
    var syms: [4 * sym_bytes]u8 = @splat(0);
    sym_write(&syms, 0, name_main, 0x12, 1, 0x401100, 0x40);
    sym_write(&syms, 1, name_helper, 0x02, 1, 0x401200, 0x10);
    sym_write(&syms, 2, name_data, 0x11, 2, 0x402800, 0x100);
    sym_write(&syms, 3, name_start, 0x12, 0, 0x401300, 0x10);

    var table = try SymbolTable.init(testing.allocator, .{
        .segments = &segments_test,
        .symtab = &syms,
        .strtab = strs_test,
    });
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), table.count);

    const first = table.lookup(0x1100).?;
    try testing.expectEqualStrings("main", first.name);
    try testing.expectEqual(@as(u64, 0), first.inside);
    const middle = table.lookup(0x1120).?;
    try testing.expectEqualStrings("main", middle.name);
    try testing.expectEqual(@as(u64, 0x20), middle.inside);
    try testing.expectEqualStrings("main", table.lookup(0x113f).?.name);

    try testing.expectEqual(@as(?Hit, null), table.lookup(0x1140));
    try testing.expectEqual(@as(?Hit, null), table.lookup(0x10ff));
    try testing.expectEqualStrings("helper", table.lookup(0x1200).?.name);
    try testing.expectEqual(@as(?Hit, null), table.lookup(0x1210));
    try testing.expectEqual(@as(?Hit, null), table.lookup(std.math.maxInt(u64)));
}

test "a function without a size lasts until the next one, and aliases keep one name" {
    var syms: [3 * sym_bytes]u8 = @splat(0);
    sym_write(&syms, 0, name_start, 0x12, 1, 0x401000, 0);
    sym_write(&syms, 1, name_main, 0x12, 1, 0x401100, 0x20);
    sym_write(&syms, 2, name_alias, 0x12, 1, 0x401100, 0x20);

    var table = try SymbolTable.init(testing.allocator, .{
        .segments = &segments_test,
        .symtab = &syms,
        .strtab = strs_test,
    });
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), table.count);
    try testing.expectEqualStrings("start", table.lookup(0x10ff).?.name);
    try testing.expectEqualStrings("start", table.lookup(0x1050).?.name);
    try testing.expectEqualStrings("main", table.lookup(0x1100).?.name);
}

test "bad symbols are skipped: bad name, address outside the segments, cut-off table" {
    var syms: [4 * sym_bytes + 10]u8 = @splat(0);
    sym_write(&syms, 0, 9999, 0x12, 1, 0x401100, 0x10);
    sym_write(&syms, 1, name_main, 0x12, 1, 0x500000, 0x10);
    sym_write(&syms, 2, 0, 0x12, 1, 0x401100, 0x10);
    sym_write(&syms, 3, name_helper, 0x12, 1, 0x401200, 0x10);

    var table = try SymbolTable.init(testing.allocator, .{
        .segments = &segments_test,
        .symtab = &syms,
        .strtab = strs_test,
    });
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), table.count);
    try testing.expectEqualStrings("helper", table.lookup(0x1200).?.name);

    var no_end = try SymbolTable.init(testing.allocator, .{
        .segments = &segments_test,
        .symtab = syms[3 * sym_bytes ..][0..sym_bytes],
        .strtab = "\x00main\x00helper",
    });
    defer no_end.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), no_end.count);
}

test "without a .symtab the dynamic symbols are used, and nothing at all is an empty table" {
    var syms: [1 * sym_bytes]u8 = @splat(0);
    sym_write(&syms, 0, name_main, 0x12, 1, 0x401100, 0x40);

    var table = try SymbolTable.init(testing.allocator, .{
        .segments = &segments_test,
        .dynsym = &syms,
        .dynstr = strs_test,
    });
    defer table.deinit(testing.allocator);
    try testing.expectEqualStrings("main", table.lookup(0x1101).?.name);

    var empty = try SymbolTable.init(testing.allocator, .{ .segments = &.{} });
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(?Hit, null), empty.lookup(0));
}

test "a function at the very last offset, with no size, does not overflow" {
    var syms: [1 * sym_bytes]u8 = @splat(0);
    sym_write(&syms, 0, name_main, 0x12, 1, 0x10, 0);
    const segments = [_]elf.Segment{.{
        .offset = std.math.maxInt(u64) - 0x10,
        .vaddr = 0,
        .filesz = 0x100,
    }};
    var table = try SymbolTable.init(testing.allocator, .{
        .segments = &segments,
        .symtab = &syms,
        .strtab = strs_test,
    });
    defer table.deinit(testing.allocator);
    try testing.expectEqualStrings("main", table.lookup(std.math.maxInt(u64)).?.name);
}

fn table_fuzz(_: void, smith: *testing.Smith) !void {
    var segments: [2]elf.Segment = undefined;
    for (&segments) |*segment| segment.* = .{
        .offset = smith.value(u64),
        .vaddr = smith.value(u64),
        .filesz = smith.value(u64),
    };
    var syms: [16 * sym_bytes]u8 = undefined;
    var strs: [256]u8 = undefined;
    const syms_len = smith.slice(&syms);
    const strs_len = smith.slice(&strs);

    var table = SymbolTable.init(testing.allocator, .{
        .segments = &segments,
        .symtab = syms[0..syms_len],
        .strtab = strs[0..strs_len],
    }) catch |err| switch (err) {
        error.TooLarge => return,
        error.OutOfMemory => return err,
    };
    defer table.deinit(testing.allocator);

    const entries = table.entries[0..table.count];
    for (entries, 0..) |entry, index| {
        if (index > 0) try testing.expect(entries[index - 1].start < entry.start);
        try testing.expect(entry.size > 0);
        try testing.expect(entry.name < table.names.len);
        const hit = table.lookup(entry.start).?;
        try testing.expectEqual(@as(u64, 0), hit.inside);
        try testing.expect(hit.name.len > 0);
    }
    _ = table.lookup(smith.value(u64));
}

test "fuzz: a table from any bytes is consistent (zig build test --fuzz)" {
    try testing.fuzz({}, table_fuzz, .{});
}

test "the table fuzz body on random inputs (until --fuzz works in this Zig)" {
    var prng = std.Random.DefaultPrng.init(0x6e75736b75);
    var input: [2048]u8 = undefined;
    for (0..2000) |_| {
        const length = prng.random().uintAtMost(usize, input.len);
        prng.random().bytes(input[0..length]);
        var smith: testing.Smith = .{ .in = input[0..length] };
        try table_fuzz({}, &smith);
    }
}
