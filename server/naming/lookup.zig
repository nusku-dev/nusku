//! Names (build ID.

const std = @import("std");
const assert = std.debug.assert;
const symbols_layer = @import("../symbols/symbols.zig");
const Symbols = symbols_layer.Symbols;

pub const Location = symbols_layer.Location;

pub const Lookup = struct {
    symbols: *Symbols,
    cache: [cache_size]Slot = @splat(.{}),

    const cache_size = 1024;

    const Slot = struct {
        build_id: []const u8 = &.{},
        offset: u64 = 0,
        frames: []const Location = &.{},
    };

    pub fn locate(
        lookup: *Lookup,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) ![]const Location {
        assert(build_id.len > 0);

        var hasher = std.hash.Wyhash.init(offset);
        hasher.update(build_id);
        const slot = &lookup.cache[hasher.final() % cache_size];
        if (slot.offset == offset and std.mem.eql(u8, slot.build_id, build_id)) return slot.frames;

        const found = try lookup.symbols.locate(arena, build_id, offset);
        slot.* = .{ .build_id = build_id, .offset = offset, .frames = found };
        return found;
    }
};

const testing = std.testing;
const table_one = @import("../testing/symbols.zig").table_one;

test "the cache keeps binaries apart, and outlives the table" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{});
    var symbols_live = true;
    defer if (symbols_live) symbols.deinit();
    const gpa = testing.allocator;
    try symbols.binaries.put(gpa, "aa", try table_one(gpa, "work"));
    try symbols.binaries.put(gpa, "bb", try table_one(gpa, "rest"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = arena.allocator();
    const lookup = try names.create(Lookup);
    lookup.* = .{ .symbols = &symbols };

    try testing.expectEqualStrings("work", (try lookup.locate(names, "aa", 0x1100))[0].function.?);
    try testing.expectEqualStrings("rest", (try lookup.locate(names, "bb", 0x1100))[0].function.?);
    try testing.expectEqual(@as(usize, 0), (try lookup.locate(names, "aa", 0x9000)).len);
    try testing.expectEqual(@as(usize, 0), (try lookup.locate(names, "cc", 0x1100)).len);

    symbols.deinit();
    symbols_live = false;
    try testing.expectEqualStrings("work", (try lookup.locate(names, "aa", 0x1100))[0].function.?);
}
