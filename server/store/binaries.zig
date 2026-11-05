//! The symbol tables the server has, by build ID. Everything is bounded when it is created: a
//! fixed number of entries and a budget of bytes. When a new table does not fit, the least
//! recently used ones are dropped until it does. A table is used when a query names an address
//! with it, and when a window arrives whose regions need it.

const std = @import("std");
const SymbolTable = @import("../symbolize/symbol_table.zig").SymbolTable;

const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    /// The table alone is bigger than the whole budget.
    TooLarge,
};

const Entry = struct {
    /// The build ID, owned by the entry.
    id: []u8,
    table: SymbolTable,
    bytes: u64,
    /// The value of the store's clock the last time this entry was put or got.
    used: u64,
};

pub const Binaries = struct {
    /// All the allocation; only the first `count` are in use.
    entries: []Entry,
    count: usize,
    bytes_max: u64,
    bytes_used: u64,
    clock: u64,
    /// Where `get` found its last table. Frames in a row are mostly in the same binary, so this
    /// saves the scan; it is only a guess, checked against the build ID before it is used.
    last: usize,

    pub fn init(gpa: std.mem.Allocator, entries_max: usize, bytes_max: u64) !Binaries {
        assert(entries_max > 0);
        return .{
            .entries = try gpa.alloc(Entry, entries_max),
            .count = 0,
            .bytes_max = bytes_max,
            .bytes_used = 0,
            .clock = 0,
            .last = 0,
        };
    }

    pub fn deinit(binaries: *Binaries, gpa: std.mem.Allocator) void {
        for (binaries.entries[0..binaries.count]) |*entry| entry_free(gpa, entry);
        gpa.free(binaries.entries);
        binaries.* = undefined;
    }

    /// Whether the table of `build_id` is here. It does not count as a use.
    pub fn has(binaries: *const Binaries, build_id: []const u8) bool {
        return binaries.find(build_id) != null;
    }

    /// The table of `build_id`, and counts as a use. The pointer is good until the next `put`
    /// (a `put` may drop it), so the caller must not hold it past the lock.
    pub fn get(binaries: *Binaries, build_id: []const u8) ?*const SymbolTable {
        const index = binaries.find_from(binaries.last, build_id) orelse return null;
        binaries.last = index;
        binaries.entries[index].used = binaries.tick();
        return &binaries.entries[index].table;
    }

    /// Takes the table: it is kept, or freed when it is not (a table that is here already, or
    /// one that cannot fit).
    pub fn put(
        binaries: *Binaries,
        gpa: std.mem.Allocator,
        build_id: []const u8,
        table: SymbolTable,
    ) Error!void {
        var owned = table;
        errdefer owned.deinit(gpa);

        if (binaries.find(build_id)) |index| {
            binaries.entries[index].used = binaries.tick();
            owned.deinit(gpa);
            return;
        }
        const bytes = owned.bytes();
        if (bytes > binaries.bytes_max) return error.TooLarge;

        // Copy the id first, so a failure here drops nothing from the store.
        const id = try gpa.dupe(u8, build_id);
        errdefer gpa.free(id);

        while (binaries.count == binaries.entries.len or
            binaries.bytes_used + bytes > binaries.bytes_max)
        {
            binaries.oldest_drop(gpa);
        }
        assert(binaries.count < binaries.entries.len);
        assert(binaries.bytes_used + bytes <= binaries.bytes_max);

        binaries.entries[binaries.count] = .{
            .id = id,
            .table = owned,
            .bytes = bytes,
            .used = binaries.tick(),
        };
        binaries.count += 1;
        binaries.bytes_used += bytes;
        binaries.verify();
    }

    /// The budget adds up. Debug builds only: it walks every entry.
    fn verify(binaries: *const Binaries) void {
        if (!std.debug.runtime_safety) return;
        var bytes: u64 = 0;
        for (binaries.entries[0..binaries.count]) |entry| bytes += entry.bytes;
        assert(bytes == binaries.bytes_used);
        assert(binaries.bytes_used <= binaries.bytes_max);
        assert(binaries.count <= binaries.entries.len);
    }

    fn find(binaries: *const Binaries, build_id: []const u8) ?usize {
        for (binaries.entries[0..binaries.count], 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, build_id)) return index;
        }
        return null;
    }

    /// `find`, trying the entry at `guess` first.
    fn find_from(binaries: *const Binaries, guess: usize, build_id: []const u8) ?usize {
        if (guess < binaries.count and std.mem.eql(u8, binaries.entries[guess].id, build_id)) {
            return guess;
        }
        return binaries.find(build_id);
    }

    fn tick(binaries: *Binaries) u64 {
        binaries.clock += 1;
        return binaries.clock;
    }

    /// Drops the entry that was used the longest ago.
    fn oldest_drop(binaries: *Binaries, gpa: std.mem.Allocator) void {
        assert(binaries.count > 0);
        var oldest: usize = 0;
        for (binaries.entries[0..binaries.count], 0..) |entry, index| {
            if (entry.used < binaries.entries[oldest].used) oldest = index;
        }
        binaries.bytes_used -= binaries.entries[oldest].bytes;
        entry_free(gpa, &binaries.entries[oldest]);
        binaries.count -= 1;
        binaries.entries[oldest] = binaries.entries[binaries.count];
    }
};

fn entry_free(gpa: std.mem.Allocator, entry: *Entry) void {
    gpa.free(entry.id);
    entry.table.deinit(gpa);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const elf = @import("shared").elf;

/// A table with one function named with `name_length` letters: 16 + name_length + 1 bytes.
fn table_make(gpa: std.mem.Allocator, name_length: usize) !SymbolTable {
    var strtab = try gpa.alloc(u8, name_length + 2);
    defer gpa.free(strtab);
    @memset(strtab, 'a');
    strtab[0] = 0;
    strtab[strtab.len - 1] = 0;

    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little); // Name at 1.
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little); // Defined.
    std.mem.writeInt(u64, sym[8..16], 0x10, .little);
    std.mem.writeInt(u64, sym[16..24], 8, .little);

    const segments = [_]elf.Segment{.{ .offset = 0, .vaddr = 0, .filesz = 0x1000 }};
    return SymbolTable.init(gpa, .{ .segments = &segments, .symtab = &sym, .strtab = strtab });
}

const table_bytes = 16 + 100 + 1;

test "a table that is put can be found, and a missing one cannot" {
    var binaries = try Binaries.init(testing.allocator, 4, 1000);
    defer binaries.deinit(testing.allocator);

    try testing.expect(!binaries.has("one"));
    try binaries.put(testing.allocator, "one", try table_make(testing.allocator, 100));
    try testing.expect(binaries.has("one"));
    try testing.expect(!binaries.has("two"));
    try testing.expectEqual(@as(u64, table_bytes), binaries.bytes_used);

    const table = binaries.get("one").?;
    try testing.expectEqualStrings("a" ** 100, table.lookup(0x10).?.name);
    try testing.expectEqual(@as(?*const SymbolTable, null), binaries.get("two"));
}

test "the same build ID put twice is kept once" {
    var binaries = try Binaries.init(testing.allocator, 4, 1000);
    defer binaries.deinit(testing.allocator);

    try binaries.put(testing.allocator, "one", try table_make(testing.allocator, 100));
    try binaries.put(testing.allocator, "one", try table_make(testing.allocator, 100));
    try testing.expectEqual(@as(usize, 1), binaries.count);
    try testing.expectEqual(@as(u64, table_bytes), binaries.bytes_used);
}

test "when the bytes do not fit, the least recently used table goes" {
    // Room for two tables, not three.
    var binaries = try Binaries.init(testing.allocator, 10, 2 * table_bytes + 10);
    defer binaries.deinit(testing.allocator);

    try binaries.put(testing.allocator, "a", try table_make(testing.allocator, 100));
    try binaries.put(testing.allocator, "b", try table_make(testing.allocator, 100));
    _ = binaries.get("a"); // "a" was used after "b", so "b" is the oldest.
    try binaries.put(testing.allocator, "c", try table_make(testing.allocator, 100));

    try testing.expect(binaries.has("a"));
    try testing.expect(!binaries.has("b"));
    try testing.expect(binaries.has("c"));
    try testing.expect(binaries.bytes_used <= binaries.bytes_max);
    try testing.expectEqual(@as(u64, 2 * table_bytes), binaries.bytes_used);
}

test "when the entries are full, the least recently used table goes" {
    var binaries = try Binaries.init(testing.allocator, 2, 1_000_000);
    defer binaries.deinit(testing.allocator);

    try binaries.put(testing.allocator, "a", try table_make(testing.allocator, 10));
    try binaries.put(testing.allocator, "b", try table_make(testing.allocator, 10));
    try binaries.put(testing.allocator, "c", try table_make(testing.allocator, 10));

    try testing.expectEqual(@as(usize, 2), binaries.count);
    try testing.expect(!binaries.has("a"));
    try testing.expect(binaries.has("b"));
    try testing.expect(binaries.has("c"));
}

test "a table bigger than the whole budget is refused and nothing is lost" {
    var binaries = try Binaries.init(testing.allocator, 4, table_bytes + 5);
    defer binaries.deinit(testing.allocator);

    try binaries.put(testing.allocator, "small", try table_make(testing.allocator, 100));
    try testing.expectError(
        error.TooLarge,
        binaries.put(testing.allocator, "big", try table_make(testing.allocator, 500)),
    );
    // The refused one did not push the other out.
    try testing.expect(binaries.has("small"));
    try testing.expect(!binaries.has("big"));
    try testing.expectEqual(@as(u64, table_bytes), binaries.bytes_used);
}

test "a get after tables moved finds the right one, whatever it found before" {
    var binaries = try Binaries.init(testing.allocator, 2, 1_000_000);
    defer binaries.deinit(testing.allocator);

    try binaries.put(testing.allocator, "a", try table_make(testing.allocator, 10));
    try binaries.put(testing.allocator, "b", try table_make(testing.allocator, 20));
    try testing.expect(binaries.get("b") != null); // The hint is now b's slot, 1.

    // "a" is the oldest: it goes, and "b" moves into its slot. The hint is stale.
    try binaries.put(testing.allocator, "c", try table_make(testing.allocator, 30));
    try testing.expectEqualStrings("a" ** 20, binaries.get("b").?.lookup(0x10).?.name);
    try testing.expectEqualStrings("a" ** 30, binaries.get("c").?.lookup(0x10).?.name);
    try testing.expectEqual(@as(?*const SymbolTable, null), binaries.get("a"));
}
