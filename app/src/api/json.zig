const std = @import("std");

pub fn of(arena: std.mem.Allocator, value: anytype) ![:0]const u8 {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    return arena.dupeZ(u8, text);
}

pub fn from_error(arena: std.mem.Allocator, err: anyerror) [:0]const u8 {
    return of(arena, .{ .@"error" = @errorName(err) }) catch "{\"error\":\"OutOfMemory\"}";
}
