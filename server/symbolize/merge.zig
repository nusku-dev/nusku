//! Merges stacks of the same call path, from any window and at any instruction of the same
//! functions, into one with the sum of their samples.

const std = @import("std");
const query = @import("../query.zig");

const Order = std.math.Order;
const Frame = query.Frame;
const SymbolStack = query.SymbolStack;

/// Merges in place, and returns the front that is kept, most samples first.
pub fn stacks_merge(stacks: []SymbolStack) []SymbolStack {
    std.mem.sort(SymbolStack, stacks, {}, stack_less);

    var kept: usize = 0;
    for (stacks) |stack| {
        if (kept > 0 and stack_order(stacks[kept - 1], stack) == .eq) {
            stacks[kept - 1].samples += stack.samples;
            continue;
        }
        stacks[kept] = stack;
        kept += 1;
    }

    const merged = stacks[0..kept];
    std.mem.sort(SymbolStack, merged, {}, samples_more);
    return merged;
}

fn stack_less(_: void, a: SymbolStack, b: SymbolStack) bool {
    return stack_order(a, b) == .lt;
}

/// Most samples first, and the same order every time.
fn samples_more(_: void, a: SymbolStack, b: SymbolStack) bool {
    if (a.samples != b.samples) return a.samples > b.samples;
    return stack_order(a, b) == .lt;
}

fn stack_order(a: SymbolStack, b: SymbolStack) Order {
    const common = @min(a.frames.len, b.frames.len);
    for (a.frames[0..common], b.frames[0..common]) |x, y| {
        const order = frame_order(x, y);
        if (order != .eq) return order;
    }
    const by_length = std.math.order(a.frames.len, b.frames.len);
    if (by_length != .eq) return by_length;
    return std.math.order(@intFromBool(a.complete), @intFromBool(b.complete));
}

/// A named frame is its function, not its instruction; an unnamed one is its raw address.
fn frame_order(a: Frame, b: Frame) Order {
    var order = std.math.order(@intFromBool(a.kernel), @intFromBool(b.kernel));
    if (order != .eq) return order;
    order = string_order(a.module, b.module);
    if (order != .eq) return order;
    order = string_order(a.function, b.function);
    if (order != .eq) return order;
    if (a.function == null) return std.math.order(a.address, b.address);
    return .eq;
}

/// Null comes before any string.
fn string_order(a: ?[]const u8, b: ?[]const u8) Order {
    if (a == null or b == null) {
        return std.math.order(@intFromBool(a != null), @intFromBool(b != null));
    }
    // Mostly the same slice: the lookup hands out one copy of each name.
    if (a.?.ptr == b.?.ptr and a.?.len == b.?.len) return .eq;
    return std.mem.order(u8, a.?, b.?);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn named(function: []const u8, module: []const u8, address: u64) Frame {
    return .{ .address = address, .kernel = false, .function = function, .module = module };
}

fn unnamed(address: u64) Frame {
    return .{ .address = address, .kernel = false };
}

test "the same call path at different instructions is one stack" {
    const first = [_]Frame{ named("leaf", "/bin/app", 0x1500), named("main", "/bin/app", 0x1604) };
    const second = [_]Frame{ named("leaf", "/bin/app", 0x1510), named("main", "/bin/app", 0x1610) };
    var stacks = [_]SymbolStack{
        .{ .samples = 3, .frames = &first, .complete = true },
        .{ .samples = 4, .frames = &second, .complete = true },
    };

    const merged = stacks_merge(&stacks);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(@as(u64, 7), merged[0].samples);
}

test "different paths, modules, completeness and unnamed addresses stay apart" {
    const base = [_]Frame{ named("leaf", "/bin/app", 1), named("main", "/bin/app", 2) };
    const other_order = [_]Frame{ named("main", "/bin/app", 2), named("leaf", "/bin/app", 1) };
    const other_module = [_]Frame{ named("leaf", "/lib/x.so", 1), named("main", "/bin/app", 2) };
    const shorter = [_]Frame{named("leaf", "/bin/app", 1)};
    const unnamed_a = [_]Frame{unnamed(0x9000)};
    const unnamed_b = [_]Frame{unnamed(0x9001)};
    var stacks = [_]SymbolStack{
        .{ .samples = 1, .frames = &base, .complete = true },
        .{ .samples = 1, .frames = &base, .complete = false }, // Stopped early: not the same.
        .{ .samples = 1, .frames = &other_order, .complete = true },
        .{ .samples = 1, .frames = &other_module, .complete = true },
        .{ .samples = 1, .frames = &shorter, .complete = true },
        .{ .samples = 1, .frames = &unnamed_a, .complete = true },
        .{ .samples = 1, .frames = &unnamed_b, .complete = true },
    };

    try testing.expectEqual(@as(usize, 7), stacks_merge(&stacks).len);
}

test "the same unnamed address merges, and kernel frames are not user frames" {
    const user = [_]Frame{unnamed(0xffff0000)};
    const kernel = [_]Frame{.{ .address = 0xffff0000, .kernel = true }};
    var stacks = [_]SymbolStack{
        .{ .samples = 2, .frames = &user, .complete = true },
        .{ .samples = 3, .frames = &user, .complete = true },
        .{ .samples = 5, .frames = &kernel, .complete = true },
    };

    const merged = stacks_merge(&stacks);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqual(@as(u64, 5), merged[0].samples);
    try testing.expectEqual(@as(u64, 5), merged[1].samples);
}

test "the result has the most samples first, and nothing in gives nothing out" {
    const a = [_]Frame{named("a", "/m", 1)};
    const b = [_]Frame{named("b", "/m", 1)};
    const c = [_]Frame{named("c", "/m", 1)};
    var stacks = [_]SymbolStack{
        .{ .samples = 2, .frames = &a, .complete = true },
        .{ .samples = 9, .frames = &b, .complete = true },
        .{ .samples = 5, .frames = &c, .complete = true },
        .{ .samples = 1, .frames = &a, .complete = true },
    };

    const merged = stacks_merge(&stacks);
    try testing.expectEqual(@as(usize, 3), merged.len);
    try testing.expectEqualStrings("b", merged[0].frames[0].function.?);
    try testing.expectEqual(@as(u64, 9), merged[0].samples);
    try testing.expectEqualStrings("c", merged[1].frames[0].function.?);
    try testing.expectEqualStrings("a", merged[2].frames[0].function.?);
    try testing.expectEqual(@as(u64, 3), merged[2].samples);

    var empty: [0]SymbolStack = .{};
    try testing.expectEqual(@as(usize, 0), stacks_merge(&empty).len);
}
