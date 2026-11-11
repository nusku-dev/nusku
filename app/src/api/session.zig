const std = @import("std");
const client = @import("client");

pub var current: client.Session = undefined;

pub fn init() !void {
    try current.init(std.heap.smp_allocator, .{});
}

pub fn deinit() void {
    current.deinit();
}
