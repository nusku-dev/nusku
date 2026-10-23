//! Totals per function: for each function, how many samples it was the innermost frame of
//! (self) and how many samples it appeared in at all (total).
const std = @import("std");
const symbolizer = @import("root.zig");

pub const FunctionTotal = struct {
    kind: symbolizer.FrameKind,
    /// Null if the function could not be named.
    name: ?[]const u8,
    /// The file it lies in. Null for the kernel and for memory without a file.
    module: ?[]const u8,
    /// Where the function starts in memory if that is known, else the one address seen for it.
    address: u64,
    /// Samples in which it was the innermost frame, so it was what the CPU was running.
    self: u64,
    /// Samples in which it appears anywhere in the stack. A function that appears several
    /// times in one stack (recursion) counts once. Never less than `self`.
    total: u64,
};

/// What makes two frames the same function: a resolved frame by where its function starts,
/// an unresolved one only by its own address (we cannot know where such a function begins).
const Key = struct {
    kind: symbolizer.FrameKind,
    resolved: bool,
    id: u64,
};

const Work = struct {
    data: FunctionTotal,
    /// The last stack that added to `data.total`, so a function appearing twice in one
    /// stack counts once.
    last_stack: usize,
    /// Where it first appeared, which settles ties between equal functions.
    order: usize,
};

/// Everything returned lives in `arena`. Names and modules still point where the frames' did.
pub fn summarize(arena: std.mem.Allocator, result: symbolizer.Result) ![]const FunctionTotal {
    var work: std.ArrayList(Work) = .empty;
    var seen: std.AutoHashMapUnmanaged(Key, usize) = .empty;

    for (result.stacks, 0..) |stack, stack_index| {
        for (stack.frames, 0..) |frame, depth| {
            const found = try seen.getOrPut(arena, .{
                .kind = frame.kind,
                .resolved = frame.function != null,
                .id = frame.function orelse frame.address,
            });
            if (!found.found_existing) {
                found.value_ptr.* = work.items.len;
                try work.append(arena, .{
                    .data = .{
                        .kind = frame.kind,
                        .name = frame.name,
                        .module = frame.module,
                        .address = frame.function orelse frame.address,
                        .self = 0,
                        .total = 0,
                    },
                    .last_stack = std.math.maxInt(usize),
                    .order = work.items.len,
                });
            }

            const entry = &work.items[found.value_ptr.*];
            if (entry.last_stack != stack_index) {
                entry.last_stack = stack_index;
                entry.data.total += stack.samples;
            }
            // Frames are root first, so the last one is what the CPU was running.
            if (depth + 1 == stack.frames.len) entry.data.self += stack.samples;
        }
    }

    std.mem.sort(Work, work.items, {}, moreCostly);

    const out = try arena.alloc(FunctionTotal, work.items.len);
    for (work.items, out) |item, *dst| dst.* = item.data;
    return out;
}

fn moreCostly(_: void, a: Work, b: Work) bool {
    if (a.data.self != b.data.self) return a.data.self > b.data.self;
    if (a.data.total != b.data.total) return a.data.total > b.data.total;
    return a.order < b.order;
}

// ------------------------------------------------------------------ tests

fn frameTest(name: []const u8, function: u64) symbolizer.Frame {
    return .{ .kind = .user, .address = function + 4, .name = name, .function = function };
}

fn unresolved(kind: symbolizer.FrameKind, address: u64) symbolizer.Frame {
    return .{ .kind = kind, .address = address };
}

test "self counts where the CPU was, total counts every stack a function is part of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const s1 = [_]symbolizer.Frame{ frameTest("main", 0x10), frameTest("work", 0x20) };
    const s2 = [_]symbolizer.Frame{ frameTest("main", 0x10), frameTest("helper", 0x30) };
    const s3 = [_]symbolizer.Frame{frameTest("main", 0x10)};
    const stacks = [_]symbolizer.SymbolizedStack{
        .{ .samples = 6, .frames = &s1 },
        .{ .samples = 3, .frames = &s2 },
        .{ .samples = 1, .frames = &s3 },
    };
    const totals = try summarize(arena.allocator(), .{ .samples = 10, .stacks = &stacks });

    try std.testing.expectEqual(@as(usize, 3), totals.len);

    try std.testing.expectEqualStrings("work", totals[0].name.?);
    try std.testing.expectEqual(@as(u64, 6), totals[0].self);
    try std.testing.expectEqual(@as(u64, 6), totals[0].total);
    try std.testing.expectEqual(@as(u64, 0x20), totals[0].address); // where the function starts

    try std.testing.expectEqualStrings("helper", totals[1].name.?);
    try std.testing.expectEqual(@as(u64, 3), totals[1].self);
    try std.testing.expectEqual(@as(u64, 3), totals[1].total);

    try std.testing.expectEqualStrings("main", totals[2].name.?);
    try std.testing.expectEqual(@as(u64, 1), totals[2].self);
    try std.testing.expectEqual(@as(u64, 10), totals[2].total);
}

test "a function that appears twice in one stack counts once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const recursive = [_]symbolizer.Frame{ frameTest("f", 0x10), frameTest("g", 0x20), frameTest("f", 0x10) };
    const stacks = [_]symbolizer.SymbolizedStack{.{ .samples = 5, .frames = &recursive }};
    const totals = try summarize(arena.allocator(), .{ .samples = 5, .stacks = &stacks });

    try std.testing.expectEqual(@as(usize, 2), totals.len);
    try std.testing.expectEqualStrings("f", totals[0].name.?);
    try std.testing.expectEqual(@as(u64, 5), totals[0].self); // innermost
    try std.testing.expectEqual(@as(u64, 5), totals[0].total); // not 10
    try std.testing.expectEqualStrings("g", totals[1].name.?);
    try std.testing.expectEqual(@as(u64, 0), totals[1].self);
    try std.testing.expectEqual(@as(u64, 5), totals[1].total);
}

test "unresolved frames are told apart by kind and address, and from resolved ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = [_]symbolizer.Frame{unresolved(.user, 0x1000)};
    const b = [_]symbolizer.Frame{unresolved(.user, 0x1000)};
    const c = [_]symbolizer.Frame{unresolved(.user, 0x2000)};
    const d = [_]symbolizer.Frame{unresolved(.kernel, 0x1000)};
    const e = [_]symbolizer.Frame{frameTest("x", 0x1000)}; // a resolved function that starts at 0x1000
    const stacks = [_]symbolizer.SymbolizedStack{
        .{ .samples = 2, .frames = &a },
        .{ .samples = 3, .frames = &b },
        .{ .samples = 1, .frames = &c },
        .{ .samples = 1, .frames = &d },
        .{ .samples = 1, .frames = &e },
    };
    const totals = try summarize(arena.allocator(), .{ .samples = 8, .stacks = &stacks });

    try std.testing.expectEqual(@as(usize, 4), totals.len);
    try std.testing.expectEqual(symbolizer.FrameKind.user, totals[0].kind);
    try std.testing.expectEqual(@as(u64, 0x1000), totals[0].address);
    try std.testing.expectEqual(@as(u64, 5), totals[0].self);
    try std.testing.expect(totals[0].name == null);
}

test "order: most self first, then most total, then first seen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const s1 = [_]symbolizer.Frame{frameTest("a", 0x10)};
    const s2 = [_]symbolizer.Frame{frameTest("b", 0x20)};
    const s3 = [_]symbolizer.Frame{ frameTest("b", 0x20), frameTest("e", 0x50) };
    const s4 = [_]symbolizer.Frame{frameTest("c", 0x30)};
    const stacks = [_]symbolizer.SymbolizedStack{
        .{ .samples = 3, .frames = &s1 },
        .{ .samples = 3, .frames = &s2 },
        .{ .samples = 2, .frames = &s3 },
        .{ .samples = 3, .frames = &s4 },
    };
    const totals = try summarize(arena.allocator(), .{ .samples = 11, .stacks = &stacks });

    // a, b and c all have self 3. b has total 5, a and c have 3 and a was seen first. e has self 2.
    try std.testing.expectEqual(@as(usize, 4), totals.len);
    try std.testing.expectEqualStrings("b", totals[0].name.?);
    try std.testing.expectEqualStrings("a", totals[1].name.?);
    try std.testing.expectEqualStrings("c", totals[2].name.?);
    try std.testing.expectEqualStrings("e", totals[3].name.?);
}

test "no stacks give no functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const totals = try summarize(arena.allocator(), .{ .samples = 0, .stacks = &.{} });
    try std.testing.expectEqual(@as(usize, 0), totals.len);
}
