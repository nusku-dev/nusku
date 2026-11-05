//! The owned form of one report: plain data that does not point into the agent's buffers,
//! so it can be kept, queued, sent to another thread, or serialized (into a protobuf message,
//! later). A `Report` is only valid during the callback; a `Message` outlives it.

const std = @import("std");
const session_file = @import("session.zig");
const Region = @import("target/regions.zig").Region;

pub const Message = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    pid: u32,
    /// Samples per second per CPU: `samples / sample_hz` is CPU seconds.
    sample_hz: u32,
    samples: u64,
    /// Samples the window misses, all reasons together (see cpu.Loss for each).
    samples_lost: u64,
    regions: []const Region,
    stacks: []const Stack,
    kernel: Kernel = .{},

    /// What the server needs to find the symbols of kernel frames.
    pub const Kernel = struct {
        release: []const u8 = "",
        build_id: ?[]const u8 = null,
        /// The run-time address of `_text`; with the symbol file's it gives the kASLR slide.
        text_address: ?u64 = null,
    };

    pub const Stack = struct {
        samples: u64,
        user: []const u64,
        kernel: []const u64,
        /// The walk reached the outermost frame: nothing is cut.
        complete: bool,

        /// The sample was taken in a system call: `user[0]` is where the call returns to, so
        /// the calling instruction is at `user[0] - 1`.
        leaf_is_return: bool = false,
        /// The kernel stack had more frames than were kept.
        kernel_truncated: bool = false,
    };

    /// The report, deep-copied into `arena`. Everything in a report points into the agent's
    /// own buffers, which the next report reuses.
    pub fn from_report(arena: std.mem.Allocator, report: *const session_file.Report) !Message {
        var message = Message{
            .start_unix_ns = report.start_unix_ns,
            .duration_ns = report.duration_ns,
            .pid = report.pid,
            .sample_hz = 0,
            .samples = 0,
            .samples_lost = 0,
            .regions = try regions_copy(arena, report.regions),
            .stacks = &.{},
            .kernel = try kernel_copy(arena, .{
                .release = report.kernel.release,
                .build_id = report.kernel.build_id,
                .text_address = report.kernel.text_address,
            }),
        };

        const window = report.cpu orelse return message;
        const loss = window.loss;
        message.sample_hz = window.sample_hz;
        message.samples = window.samples;
        message.samples_lost = loss.ring_full + loss.counts_full + loss.frames_missing;

        const stacks = try arena.alloc(Stack, window.stacks.len);
        for (stacks, window.stacks) |*copy, stack| {
            copy.* = try stack_copy(arena, .{
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

    /// A deep copy into `arena`, which may be a fixed buffer: a message too big for it
    /// returns `error.OutOfMemory` and leaves nothing half-owned for the caller to free.
    pub fn clone(message: *const Message, arena: std.mem.Allocator) !Message {
        const stacks = try arena.alloc(Stack, message.stacks.len);
        for (stacks, message.stacks) |*copy, stack| copy.* = try stack_copy(arena, stack);

        var copy = message.*;
        copy.regions = try regions_copy(arena, message.regions);
        copy.stacks = stacks;
        copy.kernel = try kernel_copy(arena, message.kernel);
        return copy;
    }

    // Each copy starts from the whole value and then replaces its slices, so a field added
    // later is copied too, and only a new slice needs a line here.

    fn stack_copy(arena: std.mem.Allocator, stack: Stack) !Stack {
        var copy = stack;
        copy.user = try arena.dupe(u64, stack.user);
        copy.kernel = try arena.dupe(u64, stack.kernel);
        return copy;
    }

    fn regions_copy(arena: std.mem.Allocator, regions: []const Region) ![]const Region {
        const copies = try arena.alloc(Region, regions.len);
        for (copies, regions) |*copy, region| {
            copy.* = region;
            copy.path = try arena.dupe(u8, region.path);
            copy.build_id = if (region.build_id) |id| try arena.dupe(u8, id) else null;
        }
        return copies;
    }

    fn kernel_copy(arena: std.mem.Allocator, kernel: Kernel) !Kernel {
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
    // Every field of a stack survives, the flags the symbolizer needs too.
    try std.testing.expect(copy.stacks[0].complete);
    try std.testing.expect(copy.stacks[0].leaf_is_return);
    try std.testing.expect(copy.stacks[0].kernel_truncated);
    try std.testing.expectEqualStrings("6.8.0-test", copy.kernel.release);
    try std.testing.expectEqual(original.kernel.text_address, copy.kernel.text_address);

    var small: [16]u8 align(8) = undefined;
    var tiny = std.heap.FixedBufferAllocator.init(&small);
    try std.testing.expectError(error.OutOfMemory, original.clone(tiny.allocator()));
}

const window_file = @import("cpu/window.zig");

const regions_test = [_]Region{.{
    .start = 0x1000,
    .end = 0x2000,
    .offset = 0,
    .inode = 7,
    .path = "/bin/app",
    .build_id = "\xaa\xbb",
}};

const stacks_test = [_]window_file.Stack{
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

const report_test = session_file.Report{
    .start_unix_ns = 11,
    .duration_ns = 22,
    .pid = 33,
    .regions = &regions_test,
    .kernel = .{
        .release = "6.8.0-test",
        .build_id = "\x01\x02",
        .text_address = 0xffffffff81000000,
    },
    .unwind = .{},
    .cpu = .{
        .sample_hz = 99,
        .samples = 7,
        .stacks = &stacks_test,
        .stops = std.mem.zeroes([window_file.stop_reason_count]u64),
        .loss = .{ .ring_full = 1, .counts_full = 2, .frames_missing = 4 },
    },
};

test "from_report copies what the server needs, and owns it" {
    const report = report_test;
    const regions = regions_test;
    const stacks = stacks_test;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try Message.from_report(arena.allocator(), &report);

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

test "from_report without the cpu metric has no stacks" {
    const report = session_file.Report{
        .start_unix_ns = 1,
        .duration_ns = 2,
        .pid = 3,
        .regions = &.{},
        .kernel = .{},
        .unwind = .{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try Message.from_report(arena.allocator(), &report);
    try std.testing.expectEqual(@as(usize, 0), message.stacks.len);
    try std.testing.expectEqual(@as(u32, 0), message.sample_hz);
}
