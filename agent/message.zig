//! What the parent sends for a window: the protocol's Message, built from the target and what
//! metrics measured, deep-copied, as the layers reuse their buffers for the next window.

const std = @import("std");
const target = @import("target/target.zig");
const metrics = @import("metrics/metrics.zig");

const Message = @import("shared").protocol.Message;

/// What a message is made of.
pub const Source = struct {
    pid: u32,
    regions: []const target.Region,
    kernel: target.KernelIdentity,
    windows: *const metrics.Windows,
};

/// The window, deep-copied into `arena`.
pub fn build(arena: std.mem.Allocator, source: Source) !Message {
    const windows = source.windows;
    var message = Message{
        .start_unix_ns = windows.start_unix_ns,
        .duration_ns = windows.duration_ns,
        .pid = source.pid,
        .sample_hz = 0,
        .samples = 0,
        .samples_lost = 0,
        .regions = try Message.regions_copy(arena, source.regions),
        .stacks = &.{},
        .kernel = try Message.kernel_copy(arena, .{
            .release = source.kernel.release,
            .build_id = source.kernel.build_id,
            .text_address = source.kernel.text_address,
        }),
    };

    const window = windows.cpu orelse return message;
    const loss = window.loss;
    message.sample_hz = window.sample_hz;
    message.samples = window.samples;
    message.samples_lost = loss.ring_full + loss.counts_full + loss.frames_missing;

    const stacks = try arena.alloc(Message.Stack, window.stacks.len);
    for (stacks, window.stacks) |*copy, stack| {
        copy.* = try Message.stack_copy(arena, .{
            .samples = stack.samples,
            .user = stack.user,
            .kernel = stack.kernel,
            .complete = stack.stop == .end,
            .leaf_is_return = stack.leaf_is_return,
            .kernel_truncated = stack.kernel_truncated,
        });
    }
    message.stacks = stacks;
    return message;
}

// ------------------------------------------------------------------------------------- tests

const regions_test = [_]target.Region{.{
    .start = 0x1000,
    .end = 0x2000,
    .offset = 0,
    .inode = 7,
    .path = "/bin/app",
    .build_id = "\xaa\xbb",
}};

const stacks_test = [_]metrics.CpuStack{
    .{
        .samples = 5,
        .user = &.{ 0x1500, 0x1600 },
        .kernel = &.{0xffffffff81000100},
        .stop = .end,
        .leaf_is_return = true,
        .kernel_truncated = true,
    },
    .{
        .samples = 2,
        .user = &.{0x1500},
        .kernel = &.{},
        .stop = .no_mapping,
        .leaf_is_return = false,
        .kernel_truncated = false,
    },
};

const windows_test = metrics.Windows{
    .start_unix_ns = 11,
    .duration_ns = 22,
    .unwind = .{},
    .cpu = .{
        .sample_hz = 99,
        .samples = 7,
        .stacks = &stacks_test,
        .stops = std.mem.zeroes(@FieldType(metrics.CpuWindow, "stops")),
        .loss = .{ .ring_full = 1, .counts_full = 2, .frames_missing = 4 },
    },
};

const source_test = Source{
    .pid = 33,
    .regions = &regions_test,
    .kernel = .{
        .release = "6.8.0-test",
        .build_id = "\x01\x02",
        .text_address = 0xffffffff81000000,
    },
    .windows = &windows_test,
};

test "build copies what the server needs, and owns it" {
    const regions = regions_test;
    const stacks = stacks_test;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try build(arena.allocator(), source_test);

    try std.testing.expectEqual(@as(u64, 11), message.start_unix_ns);
    try std.testing.expectEqual(@as(u64, 22), message.duration_ns);
    try std.testing.expectEqual(@as(u32, 33), message.pid);
    try std.testing.expectEqual(@as(u32, 99), message.sample_hz);
    try std.testing.expectEqual(@as(u64, 7), message.samples);
    try std.testing.expectEqual(@as(u64, 7), message.samples_lost); // 1 + 2 + 4

    // The regions, with their build IDs, in memory the message owns.
    try std.testing.expectEqual(@as(usize, 1), message.regions.len);
    try std.testing.expectEqualStrings("/bin/app", message.regions[0].path);
    try std.testing.expectEqualSlices(u8, "\xaa\xbb", message.regions[0].build_id.?);
    try std.testing.expect(message.regions[0].path.ptr != regions[0].path.ptr);
    try std.testing.expect(message.regions[0].build_id.?.ptr != regions[0].build_id.?.ptr);

    // The stacks: what the walk ended on becomes "complete", and the syscall flag survives.
    try std.testing.expectEqual(@as(usize, 2), message.stacks.len);
    try std.testing.expect(message.stacks[0].complete);
    try std.testing.expect(message.stacks[0].leaf_is_return);
    try std.testing.expect(message.stacks[0].kernel_truncated);
    try std.testing.expectEqualSlices(u64, &.{ 0x1500, 0x1600 }, message.stacks[0].user);
    try std.testing.expectEqualSlices(u64, &.{0xffffffff81000100}, message.stacks[0].kernel);
    try std.testing.expect(!message.stacks[1].complete);
    try std.testing.expect(!message.stacks[1].leaf_is_return);
    try std.testing.expect(message.stacks[0].user.ptr != stacks[0].user.ptr);

    // The kernel, so the server can find its symbols.
    try std.testing.expectEqualStrings("6.8.0-test", message.kernel.release);
    try std.testing.expectEqualSlices(u8, "\x01\x02", message.kernel.build_id.?);
    try std.testing.expectEqual(@as(?u64, 0xffffffff81000000), message.kernel.text_address);
}

test "build without the cpu metric has no stacks" {
    const windows = metrics.Windows{ .start_unix_ns = 1, .duration_ns = 2, .unwind = .{} };
    const source = Source{ .pid = 3, .regions = &.{}, .kernel = .{}, .windows = &windows };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try build(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), message.stacks.len);
    try std.testing.expectEqual(@as(u32, 0), message.sample_hz);
}
