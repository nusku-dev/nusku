const std = @import("std");

pub fn of(arena: std.mem.Allocator, value: anytype) ![:0]const u8 {
    return with(arena, value, .{});
}

pub fn exact(arena: std.mem.Allocator, value: anytype) ![:0]const u8 {
    return with(arena, value, .{ .emit_nonportable_numbers_as_strings = true });
}

fn with(arena: std.mem.Allocator, value: anytype, ops: std.json.Stringify.Options) ![:0]const u8 {
    const text = try std.json.Stringify.valueAlloc(arena, value, ops);
    return arena.dupeZ(u8, text);
}

pub fn from_error(arena: std.mem.Allocator, err: anyerror) [:0]const u8 {
    return of(arena, .{ .@"error" = @errorName(err) }) catch "{\"error\":\"OutOfMemory\"}";
}

test "a number past 2^53 goes out as a string, so the UI reads it exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = .{ .small = @as(u64, 7), .address = @as(u64, 0xffffffff81000000) };
    const text = try exact(arena.allocator(), value);
    try std.testing.expectEqualStrings("{\"small\":7,\"address\":\"18446744071578845184\"}", text);
}
