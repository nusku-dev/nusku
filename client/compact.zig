//! A profile packed for the wire and for saved runs: strings once, frames as indexes.

const std = @import("std");
const server = @import("server");

pub const Frame = struct {
    a: []const u8,
    k: bool,
    f: i32,
    s: i32,
    l: u32,
    m: i32,
    i: bool,
};

pub const Stack = struct {
    d: u32,
    n: u64,
    c: bool,
    f: []const Frame,
};

pub const Compact = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    windows_rejected: u64,
    windows: @FieldType(server.Profile, "windows"),
    strings: []const []const u8,
    stacks: []const Stack,
};

/// The profile as JSON, numbers past 2^53 as strings so JavaScript reads them exactly.
pub fn json_of(arena: std.mem.Allocator, profile: *const server.Profile) ![]const u8 {
    const value = try of(arena, profile, &.{});
    const options = std.json.Stringify.Options{ .emit_nonportable_numbers_as_strings = true };
    return std.json.Stringify.valueAlloc(arena, value, options);
}

pub fn of(arena: std.mem.Allocator, profile: *const server.Profile, ids: []const u32) !Compact {
    std.debug.assert(ids.len == 0 or ids.len == profile.stacks.len);
    var strings = Strings{ .arena = arena };
    const stacks = try arena.alloc(Stack, profile.stacks.len);
    for (profile.stacks, stacks, 0..) |stack, *out, index| {
        const frames = try arena.alloc(Frame, stack.frames.len);
        for (stack.frames, frames) |frame, *packed_frame| {
            packed_frame.* = .{
                .a = try std.fmt.allocPrint(arena, "{x}", .{frame.address}),
                .k = frame.kernel,
                .f = try strings.index(frame.function),
                .s = try strings.index(frame.file),
                .l = frame.line orelse 0,
                .m = try strings.index(frame.module),
                .i = frame.inlined,
            };
        }
        const id: u32 = if (ids.len > 0) ids[index] else @intCast(index + 1);
        out.* = .{ .d = id, .n = stack.samples, .c = stack.complete, .f = frames };
    }
    return .{
        .sample_hz = profile.sample_hz,
        .samples = profile.samples,
        .samples_lost = profile.samples_lost,
        .windows_rejected = profile.windows_rejected,
        .windows = profile.windows,
        .strings = strings.list.items,
        .stacks = stacks,
    };
}

const Strings = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,
    known: std.StringHashMapUnmanaged(i32) = .empty,

    fn index(strings: *Strings, text: ?[]const u8) !i32 {
        const value = text orelse return -1;
        const entry = try strings.known.getOrPut(strings.arena, value);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(strings.list.items.len);
            try strings.list.append(strings.arena, value);
        }
        return entry.value_ptr.*;
    }
};

const testing = std.testing;

fn frame_test(address: u64, function: []const u8, line: u32, inlined: bool) server.Frame {
    return .{
        .address = address,
        .kernel = false,
        .function = function,
        .file = "/src/a.c",
        .line = line,
        .module = "/bin/app",
        .inlined = inlined,
    };
}

test "a string is sent once, and frames point at it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frames = [_]server.Frame{
        frame_test(0x1a, "run", 3, false),
        frame_test(0x2b, "main", 9, true),
        .{ .address = 0xffffffff81000000, .kernel = true },
    };
    const stacks = [_]server.SymbolStack{.{ .samples = 4, .frames = &frames, .complete = true }};
    const profile = server.Profile{
        .sample_hz = 99,
        .samples = 4,
        .samples_lost = 0,
        .windows_rejected = 0,
        .stacks = &stacks,
    };
    const compact = try of(arena.allocator(), &profile, &.{});
    try testing.expectEqual(@as(usize, 4), compact.strings.len);
    const packed_frames = compact.stacks[0].f;
    try testing.expectEqual(packed_frames[0].s, packed_frames[1].s);
    try testing.expectEqual(packed_frames[0].m, packed_frames[1].m);
    try testing.expect(packed_frames[1].i);
    try testing.expectEqual(@as(i32, -1), packed_frames[2].f);
    try testing.expectEqualStrings("ffffffff81000000", packed_frames[2].a);
}
