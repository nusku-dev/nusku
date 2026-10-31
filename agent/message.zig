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

    pub const Stack = struct {
        samples: u64,
        user: []const u64,
        kernel: []const u64,
        /// The walk reached the outermost frame: nothing is cut.
        complete: bool,
    };

    /// The report, deep-copied into `arena`. Everything in a report points into the agent's
    /// own buffers, which the next report reuses.
    pub fn from_report(arena: std.mem.Allocator, report: *const session_file.Report) !Message {
        const regions = try arena.alloc(Region, report.regions.len);

        for (regions, report.regions) |*copy, region| {
            copy.* = region;
            copy.path = try arena.dupe(u8, region.path);
            copy.build_id = if (region.build_id) |id| try arena.dupe(u8, id) else null;
        }

        var message = Message{
            .start_unix_ns = report.start_unix_ns,
            .duration_ns = report.duration_ns,
            .pid = report.pid,
            .sample_hz = 0,
            .samples = 0,
            .samples_lost = 0,
            .regions = regions,
            .stacks = &.{},
        };

        const window = report.cpu orelse return message;
        const loss = window.loss;
        message.sample_hz = window.sample_hz;
        message.samples = window.samples;
        message.samples_lost = loss.ring_full + loss.counts_full + loss.frames_missing;

        const stacks = try arena.alloc(Stack, window.stacks.len);

        for (stacks, window.stacks) |*copy, stack| {
            copy.* = .{
                .samples = stack.samples,
                .user = try arena.dupe(u64, stack.user),
                .kernel = try arena.dupe(u64, stack.kernel),
                .complete = stack.stop == .end,
            };
        }
        message.stacks = stacks;

        return message;
    }

    /// A deep copy into `arena`, which may be a fixed buffer: a message too big for it
    /// returns `error.OutOfMemory` and leaves nothing half-owned for the caller to free.
    pub fn clone(message: *const Message, arena: std.mem.Allocator) !Message {
        const regions = try arena.alloc(Region, message.regions.len);
        for (regions, message.regions) |*copy, region| {
            copy.* = region;
            copy.path = try arena.dupe(u8, region.path);
            copy.build_id = if (region.build_id) |id| try arena.dupe(u8, id) else null;
        }

        const stacks = try arena.alloc(Stack, message.stacks.len);
        for (stacks, message.stacks) |*copy, stack| {
            copy.* = .{
                .samples = stack.samples,
                .user = try arena.dupe(u64, stack.user),
                .kernel = try arena.dupe(u64, stack.kernel),
                .complete = stack.complete,
            };
        }

        var copy = message.*;
        copy.regions = regions;
        copy.stacks = stacks;
        return copy;
    }
};

test "clone copies into the given buffer, and fails when it is too small" {
    const stacks = [_]Message.Stack{.{ .samples = 7, .user = &.{ 1, 2, 3 }, .kernel = &.{9}, .complete = true }};
    const original = Message{
        .start_unix_ns = 5,
        .duration_ns = 6,
        .pid = 1,
        .sample_hz = 99,
        .samples = 7,
        .samples_lost = 0,
        .regions = &.{},
        .stacks = &stacks,
    };

    var buffer: [256]u8 align(8) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const copy = try original.clone(fixed.allocator());
    try std.testing.expectEqual(@as(u64, 5), copy.start_unix_ns);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, copy.stacks[0].user);
    try std.testing.expect(copy.stacks[0].user.ptr != original.stacks[0].user.ptr);

    var small: [16]u8 align(8) = undefined;
    var tiny = std.heap.FixedBufferAllocator.init(&small);
    try std.testing.expectError(error.OutOfMemory, original.clone(tiny.allocator()));
}
