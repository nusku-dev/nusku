//! One report of a run.

const std = @import("std");

pub const Region = struct {
    start: u64,
    end: u64,
    offset: u64,
    inode: u64,
    path: []const u8,
    build_id: ?[]const u8,
};

pub const Message = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    pid: u32,
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    regions: []const Region,
    stacks: []const Stack,
    kernel: Kernel = .{},

    pub const Kernel = struct {
        release: []const u8 = "",
        build_id: ?[]const u8 = null,
        text_address: ?u64 = null,
    };

    pub const Stack = struct {
        samples: u64,
        user: []const u64,
        kernel: []const u64,
        complete: bool,
        leaf_is_return: bool = false,
        kernel_truncated: bool = false,
    };

    pub fn clone(message: *const Message, arena: std.mem.Allocator) !Message {
        const stacks = try arena.alloc(Stack, message.stacks.len);
        for (stacks, message.stacks) |*copy, stack| copy.* = try stack_copy(arena, stack);

        var copy = message.*;
        copy.regions = try regions_copy(arena, message.regions);
        copy.stacks = stacks;
        copy.kernel = try kernel_copy(arena, message.kernel);
        return copy;
    }

    pub fn stack_copy(arena: std.mem.Allocator, stack: Stack) !Stack {
        var copy = stack;
        copy.user = try arena.dupe(u64, stack.user);
        copy.kernel = try arena.dupe(u64, stack.kernel);
        return copy;
    }

    pub fn regions_copy(arena: std.mem.Allocator, regions: []const Region) ![]const Region {
        const copies = try arena.alloc(Region, regions.len);
        for (copies, regions) |*copy, region| {
            copy.* = region;
            copy.path = try arena.dupe(u8, region.path);
            copy.build_id = if (region.build_id) |id| try arena.dupe(u8, id) else null;
        }
        return copies;
    }

    pub fn kernel_copy(arena: std.mem.Allocator, kernel: Kernel) !Kernel {
        var copy = kernel;
        copy.release = try arena.dupe(u8, kernel.release);
        copy.build_id = if (kernel.build_id) |id| try arena.dupe(u8, id) else null;
        return copy;
    }
};

test "clone copies into the given buffer, and fails when it is too small" {
    const stacks = [_]Message.Stack{.{
        .samples = 7,
        .user = &.{ 1, 2, 3 },
        .kernel = &.{9},
        .complete = true,
        .leaf_is_return = true,
        .kernel_truncated = true,
    }};
    const original = Message{
        .start_unix_ns = 5,
        .duration_ns = 6,
        .pid = 1,
        .sample_hz = 99,
        .samples = 7,
        .samples_lost = 0,
        .regions = &.{},
        .stacks = &stacks,
        .kernel = .{ .release = "6.8.0-test", .text_address = 0xffffffff81000000 },
    };

    var buffer: [256]u8 align(8) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const copy = try original.clone(fixed.allocator());
    try std.testing.expectEqual(@as(u64, 5), copy.start_unix_ns);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, copy.stacks[0].user);
    try std.testing.expect(copy.stacks[0].user.ptr != original.stacks[0].user.ptr);
    try std.testing.expect(copy.stacks[0].complete);
    try std.testing.expect(copy.stacks[0].leaf_is_return);
    try std.testing.expect(copy.stacks[0].kernel_truncated);
    try std.testing.expectEqualStrings("6.8.0-test", copy.kernel.release);
    try std.testing.expectEqual(original.kernel.text_address, copy.kernel.text_address);

    var small: [16]u8 align(8) = undefined;
    var tiny = std.heap.FixedBufferAllocator.init(&small);
    try std.testing.expectError(error.OutOfMemory, original.clone(tiny.allocator()));
}
