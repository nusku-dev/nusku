//! Names (build ID, file offset) pairs for one query, through a cache in front of the tables.
//! The same return addresses recur in almost every stack, and a pair names the same function
//! forever, so a cached name stays right even if its table is evicted meanwhile.

const std = @import("std");
const assert = std.debug.assert;
const Lock = @import("../os/lock.zig").Lock;
const Binaries = @import("../store/binaries.zig").Binaries;

pub const Lookup = struct {
    /// Taken for one table lookup at a time, never for the whole query.
    lock: *Lock,
    binaries: *Binaries,
    cache: [cache_size]Slot = @splat(.{}),

    const cache_size = 1024;

    const Slot = struct {
        /// Points into the query's windows, which outlive the lookup. Empty: unused.
        build_id: []const u8 = &.{},
        offset: u64 = 0,
        name: ?[]const u8 = null,
    };

    /// The function at `offset` of binary `build_id`, copied into `arena`, or null.
    pub fn name(
        lookup: *Lookup,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        assert(build_id.len > 0);

        var hasher = std.hash.Wyhash.init(offset);
        hasher.update(build_id);
        const slot = &lookup.cache[hasher.final() % cache_size];
        if (slot.offset == offset and std.mem.eql(u8, slot.build_id, build_id)) return slot.name;

        const found = try lookup.name_find(arena, build_id, offset);
        slot.* = .{ .build_id = build_id, .offset = offset, .name = found };
        return found;
    }

    fn name_find(
        lookup: *Lookup,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        lookup.lock.lock();
        defer lookup.lock.unlock();

        const table = lookup.binaries.get(build_id) orelse return null;
        const hit = table.lookup(offset) orelse return null;
        return try arena.dupe(u8, hit.name);
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const elf = @import("shared").elf;
const SymbolTable = @import("symbol_table.zig").SymbolTable;

/// A table with one function, `function`, at file offset 0x1100 .. 0x1140.
fn table_one(gpa: std.mem.Allocator, function: *const [4]u8) !SymbolTable {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    const segments = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};
    const strtab = "\x00" ++ function ++ "\x00";
    return SymbolTable.init(gpa, .{ .segments = &segments, .symtab = &sym, .strtab = strtab });
}

test "the cache keeps binaries apart, and outlives the table" {
    var lock = Lock{};
    var binaries = try Binaries.init(testing.allocator, 4, 1 << 20);
    try binaries.put(testing.allocator, "aa", try table_one(testing.allocator, "work"));
    try binaries.put(testing.allocator, "bb", try table_one(testing.allocator, "rest"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = arena.allocator();
    const lookup = try names.create(Lookup);
    lookup.* = .{ .lock = &lock, .binaries = &binaries };

    const none: ?[]const u8 = null;
    try testing.expectEqualStrings("work", (try lookup.name(names, "aa", 0x1100)).?);
    try testing.expectEqualStrings("rest", (try lookup.name(names, "bb", 0x1100)).?);
    try testing.expectEqual(none, try lookup.name(names, "aa", 0x9000));
    try testing.expectEqual(none, try lookup.name(names, "cc", 0x1100));

    // Every table gone: the cached answer is still right.
    binaries.deinit(testing.allocator);
    binaries = try Binaries.init(testing.allocator, 4, 1 << 20);
    defer binaries.deinit(testing.allocator);
    try testing.expectEqualStrings("work", (try lookup.name(names, "aa", 0x1100)).?);
}
