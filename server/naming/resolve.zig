//! Names the frames of one window: each address is placed in its region's file, then named by
//! `lookup`, anything with `name(arena, build_id, offset) !?[]const u8`. The result points
//! into `message` (module paths) and `arena` (names).

const std = @import("std");
const protocol = @import("shared").protocol;
const query = @import("../naming.zig");
const regions_file = @import("regions.zig");
const normalize = @import("normalize.zig");

const assert = std.debug.assert;
const Message = protocol.Message;
const Region = protocol.Region;
const Frame = query.Frame;
const SymbolStack = query.SymbolStack;
const Location = normalize.Location;

/// One resolved stack for each stack of the window, in the same order.
pub fn window_resolve(
    arena: std.mem.Allocator,
    lookup: anytype,
    message: *const Message,
) ![]SymbolStack {
    // Regions not sorted and apart would mislead the search: then every address is in none.
    const regions = if (regions_file.valid(message.regions)) message.regions else &.{};

    // One scratch for every stack's locations.
    var user_max: usize = 0;
    for (message.stacks) |stack| user_max = @max(user_max, stack.user.len);
    const locations = try arena.alloc(Location, user_max);

    const kernel = try kernel_of(arena, message);
    const stacks = try arena.alloc(SymbolStack, message.stacks.len);
    for (message.stacks, stacks) |stack, *out| {
        const scratch = locations[0..stack.user.len];
        out.* = try stack_resolve(arena, lookup, regions, kernel, scratch, stack);
    }
    return stacks;
}

/// What names a kernel frame: the kernel's identity for this boot, and its `_text`.
const Kernel = struct {
    /// In `arena`: the lookup's cache keeps it for the query.
    id: []const u8,
    text_address: u64,
};

fn kernel_of(arena: std.mem.Allocator, message: *const Message) !?Kernel {
    var buffer: [protocol.kernel.id_bytes_max]u8 = undefined;
    const kernel = &message.kernel;
    const id = protocol.kernel.id(&buffer, kernel.build_id, kernel.text_address) orelse
        return null;
    return .{ .id = try arena.dupe(u8, id), .text_address = kernel.text_address.? };
}

/// `regions` are valid; `locations` is scratch, as long as the user frames.
fn stack_resolve(
    arena: std.mem.Allocator,
    lookup: anytype,
    regions: []const Region,
    kernel: ?Kernel,
    locations: []Location,
    stack: Message.Stack,
) !SymbolStack {
    assert(locations.len == stack.user.len);
    const frames = try arena.alloc(Frame, stack.kernel.len + stack.user.len);

    // Kernel frames are innermost. Named at their distance from `_text`; after the first, a
    // frame is a return address, so the call is one byte back.
    for (stack.kernel, frames[0..stack.kernel.len], 0..) |address, *frame, index| {
        frame.* = .{ .address = address, .kernel = true };
        const known = kernel orelse continue;
        frame.module = protocol.kernel.path;
        const offset = address -% known.text_address -% @intFromBool(index > 0);
        frame.function = try lookup.name(arena, known.id, offset);
    }

    normalize.user_locate(regions, stack.user, stack.leaf_is_return, locations);
    const user_frames = frames[stack.kernel.len..];
    for (stack.user, locations, user_frames) |address, location, *frame| {
        frame.* = .{ .address = address, .kernel = false };
        if (!location.mapped()) continue;

        const region = &regions[location.region];
        if (region.path.len > 0) frame.module = region.path;
        const build_id = region.build_id orelse continue;
        frame.function = try lookup.name(arena, build_id, location.offset);
    }
    return .{ .samples = stack.samples, .frames = frames, .complete = stack.complete };
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// Knows two functions of the binary "aa".
const Fake = struct {
    asked: u32 = 0,

    pub fn name(
        fake: *Fake,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        fake.asked += 1;
        if (!std.mem.eql(u8, build_id, "aa")) return null;
        return switch (offset) {
            0x500 => try arena.dupe(u8, "leaf_fn"),
            0x603 => try arena.dupe(u8, "caller_fn"),
            else => null,
        };
    }
};

fn region_test(start: u64, end: u64, path: []const u8, id: ?[]const u8) Region {
    return .{
        .start = start,
        .end = end,
        .offset = 0,
        .inode = 1,
        .path = path,
        .build_id = id,
    };
}

fn message_test(regions: []const Region, stacks: []const Message.Stack) Message {
    return .{
        .start_unix_ns = 1,
        .duration_ns = 1,
        .pid = 1,
        .sample_hz = 99,
        .samples = 1,
        .samples_lost = 0,
        .regions = regions,
        .stacks = stacks,
    };
}

test "user frames are placed in their region and named, innermost first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const regions = [_]Region{region_test(0x1000, 0x2000, "/bin/app", "aa")};
    // The leaf is exact; the next one is a return address, so the call is at 0x1603.
    const stacks = [_]Message.Stack{.{
        .samples = 7,
        .user = &.{ 0x1500, 0x1604 },
        .kernel = &.{},
        .complete = true,
    }};
    var fake = Fake{};
    const resolved = try window_resolve(arena.allocator(), &fake, &message_test(&regions, &stacks));

    try testing.expectEqual(@as(usize, 1), resolved.len);
    try testing.expectEqual(@as(u64, 7), resolved[0].samples);
    try testing.expect(resolved[0].complete);
    const frames = resolved[0].frames;
    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expectEqualStrings("leaf_fn", frames[0].function.?);
    try testing.expectEqualStrings("caller_fn", frames[1].function.?);
    try testing.expectEqual(@as(u64, 0x1604), frames[1].address); // The raw address is kept.
    try testing.expectEqualStrings("/bin/app", frames[0].module.?);
    try testing.expect(!frames[0].kernel);
}

test "a leaf that is a return address is looked up one byte back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const regions = [_]Region{region_test(0x1000, 0x2000, "/bin/app", "aa")};
    const stacks = [_]Message.Stack{.{
        .samples = 1,
        .user = &.{0x1500},
        .kernel = &.{},
        .complete = true,
        .leaf_is_return = true,
    }};
    var fake = Fake{};
    const resolved = try window_resolve(arena.allocator(), &fake, &message_test(&regions, &stacks));
    // 0x14ff is offset 0x4ff, which the fake does not know.
    try testing.expectEqual(@as(?[]const u8, null), resolved[0].frames[0].function);
}

test "kernel frames come first, and what cannot be named keeps its address" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const regions = [_]Region{region_test(0x1000, 0x2000, "/bin/app", null)};
    const stacks = [_]Message.Stack{.{
        .samples = 1,
        .user = &.{ 0x1500, 0x9000 },
        .kernel = &.{0xffffffff81000000},
        .complete = false,
    }};
    var fake = Fake{};
    const resolved = try window_resolve(arena.allocator(), &fake, &message_test(&regions, &stacks));

    const frames = resolved[0].frames;
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expect(frames[0].kernel);
    try testing.expectEqual(@as(u64, 0xffffffff81000000), frames[0].address);
    try testing.expectEqual(@as(?[]const u8, null), frames[0].function);
    // In a region, but the file has no build ID: the module is known, the function is not.
    try testing.expectEqualStrings("/bin/app", frames[1].module.?);
    try testing.expectEqual(@as(?[]const u8, null), frames[1].function);
    // In no region at all.
    try testing.expectEqual(@as(?[]const u8, null), frames[2].module);
    try testing.expectEqual(@as(u64, 0x9000), frames[2].address);
    try testing.expect(!resolved[0].complete);
    try testing.expectEqual(@as(u32, 0), fake.asked); // Nothing to ask without a build ID.
}

test "regions that overlap are not trusted, and the frames are still there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const regions = [_]Region{
        region_test(0x1000, 0x3000, "/bin/app", "aa"),
        region_test(0x2000, 0x4000, "/lib/x.so", "bb"),
    };
    const stacks = [_]Message.Stack{.{
        .samples = 1,
        .user = &.{ 0x1500, 0x2500 },
        .kernel = &.{},
        .complete = true,
    }};
    var fake = Fake{};
    const resolved = try window_resolve(arena.allocator(), &fake, &message_test(&regions, &stacks));

    try testing.expectEqual(@as(usize, 2), resolved[0].frames.len);
    try testing.expectEqual(@as(?[]const u8, null), resolved[0].frames[0].function);
    try testing.expectEqual(@as(?[]const u8, null), resolved[0].frames[0].module);
    try testing.expectEqual(@as(u32, 0), fake.asked);
}

test "kernel frames are named at their distance from _text, with the kernel's identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const text: u64 = 0xffffffff9a000000; // Where KASLR put it this boot.
    const KernelFake = struct {
        id_expected: []const u8,
        asked: [2]u64 = undefined,
        count: usize = 0,

        pub fn name(
            fake: *@This(),
            names: std.mem.Allocator,
            build_id: []const u8,
            offset: u64,
        ) !?[]const u8 {
            try testing.expectEqualSlices(u8, fake.id_expected, build_id);
            fake.asked[fake.count] = offset;
            fake.count += 1;
            return try names.dupe(u8, if (offset < 0x200) "do_syscall_64" else "entry_SYSCALL_64");
        }
    };
    var id_buffer: [protocol.kernel.id_bytes_max]u8 = undefined;
    var fake = KernelFake{ .id_expected = protocol.kernel.id(&id_buffer, "kk", text).? };

    const stacks = [_]Message.Stack{.{
        .samples = 1,
        .user = &.{},
        .kernel = &.{ text + 0x100, text + 0x501 },
        .complete = true,
    }};
    var message = message_test(&.{}, &stacks);
    message.kernel = .{ .release = "test", .build_id = "kk", .text_address = text };
    const resolved = try window_resolve(arena.allocator(), &fake, &message);

    // The leaf is exact; the next is a return address, looked up one byte back.
    try testing.expectEqual(@as(u64, 0x100), fake.asked[0]);
    try testing.expectEqual(@as(u64, 0x500), fake.asked[1]);
    try testing.expectEqualStrings("do_syscall_64", resolved[0].frames[0].function.?);
    try testing.expectEqualStrings("[kernel]", resolved[0].frames[0].module.?);
    try testing.expect(resolved[0].frames[1].kernel);

    // A window that does not say where `_text` is: the addresses stay as they are.
    message.kernel.text_address = null;
    const unnamed = try window_resolve(arena.allocator(), &fake, &message);
    try testing.expectEqual(@as(?[]const u8, null), unnamed[0].frames[0].function);
    try testing.expectEqual(@as(usize, 2), fake.count);
}
