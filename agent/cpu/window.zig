//! One window of on-CPU samples: what the CPU metric reports at every interval.
//!
//! The types here are the CPU part of the report the agent hands out, and later sends over the
//! wire, so they are plain data: numbers, enums, and slices of addresses. Symbols are resolved
//! elsewhere (the server), from the addresses and the target's regions.

const std = @import("std");
const assert = std.debug.assert;
const cpu_wire = @import("../bpf/kernel/shared/cpu_wire.zig");
const frame_cache = @import("frame_cache.zig");

pub const StopReason = cpu_wire.StopReason;
pub const stop_reason_count = cpu_wire.stop_reason_count;

pub const Stack = struct {
    /// How many samples hit exactly this stack in the window.
    samples: u64,
    /// Return addresses, innermost first. The first is the instruction that was running, unless
    /// `leaf_is_return` says it is a return address too.
    user: []const u64,
    /// Kernel addresses, innermost first. Empty for samples taken in user mode.
    kernel: []const u64,
    /// Why the walk of the user stack ended. `end` means the stack is complete.
    stop: StopReason,
    /// The sample was taken during a system call, so the first user address is where the call
    /// returns to: look up `user[0] - 1` for the calling instruction.
    leaf_is_return: bool,
    /// The kernel stack had more frames than were kept.
    kernel_truncated: bool,
};

/// Samples that are missing from the window, and why. None of these are in `Window.samples`.
pub const Loss = struct {
    /// The ring buffer was full when the sample's stack was new to the generation.
    ring_full: u64 = 0,
    /// The counts map was full: the stack could not be counted.
    counts_full: u64 = 0,
    /// Counted, but the frames never reached the agent (the frame cache was full).
    frames_missing: u64 = 0,
    /// Ring records the agent refused as malformed. Should stay 0: the kernel writes them.
    records_malformed: u64 = 0,
    /// Walks found unfinished by a later sample. Should stay 0: it would be a bug.
    walks_abandoned: u64 = 0,
};

pub const Window = struct {
    /// Samples per second on each CPU. `samples / sample_hz` is CPU seconds.
    sample_hz: u32,
    /// Samples in the window: always the sum over `stacks`.
    samples: u64,
    /// Most samples first.
    stacks: []const Stack,
    /// The window's samples by why their walk stopped, indexed by StopReason. The sum is
    /// `samples`. The ones under `end` have a complete user stack; the others say where theirs
    /// is cut.
    stops: [stop_reason_count]u64,
    loss: Loss,
};

/// What `stacks_build` found.
pub const Built = struct {
    stacks: []Stack,
    samples: u64,
    stops: [stop_reason_count]u64,
    /// Samples whose stack had no frames in the cache.
    frames_missing: u64,
};

/// Joins the drained counts with their frames, into `target`, most samples first. The stacks
/// refer to the cache's frames, so they are valid until the cache's next epoch_advance.
pub fn stacks_build(
    target: []Stack,
    keys: []const cpu_wire.CountKey,
    values: []const u64,
    cache: *const frame_cache.FrameCache,
) Built {
    assert(keys.len == values.len);
    assert(keys.len <= target.len);

    var built = Built{
        .stacks = target[0..0],
        .samples = 0,
        .stops = @splat(0),
        .frames_missing = 0,
    };
    var count: u32 = 0;
    for (keys, values) |key, samples| {
        // The kernel inserts a key with a count of 1, so a count is never 0.
        assert(samples > 0);
        const record = cache.find(.{ .hash = key.stack_hash, .tgid = key.tgid }) orelse {
            built.frames_missing += samples;
            continue;
        };
        // The cache refused records whose stop reason is not a StopReason.
        const stop: StopReason = @enumFromInt(record.header.stop_reason);
        target[count] = .{
            .samples = samples,
            .user = record.user(),
            .kernel = record.kernel(),
            .stop = stop,
            .leaf_is_return = record.header.flags & cpu_wire.record_flag_leaf_is_return != 0,
            .kernel_truncated = record.header.flags & cpu_wire.record_flag_kernel_truncated != 0,
        };
        count += 1;
        built.samples += samples;
        built.stops[@intFromEnum(stop)] += samples;
    }
    built.stacks = target[0..count];
    std.mem.sortUnstable(Stack, built.stacks, {}, samples_more);
    return built;
}

fn samples_more(_: void, a: Stack, b: Stack) bool {
    return a.samples > b.samples;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn record_encode(buffer: []u8, hash: u64, stop: StopReason, frames: []const u64) []u8 {
    const header = cpu_wire.RecordHeader{
        .stack_hash = hash,
        .tgid = 7,
        .user_frame_count = @intCast(frames.len),
        .kernel_frame_count = 0,
        .stop_reason = @intFromEnum(stop),
        .flags = cpu_wire.record_flag_leaf_is_return,
    };
    const header_size = @sizeOf(cpu_wire.RecordHeader);
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));
    @memcpy(buffer[header_size..][0 .. frames.len * 8], std.mem.sliceAsBytes(frames));
    return buffer[0 .. header_size + frames.len * 8];
}

test "counts are joined with their frames, sorted, and the totals add up" {
    var cache: frame_cache.FrameCache = undefined;
    try cache.init(testing.allocator, .{ .stacks_max = 8, .frames_max = 1024 });
    defer cache.deinit(testing.allocator);
    var buffer: [256]u8 = undefined;

    cache.record_add(record_encode(&buffer, 1, .end, &.{ 0x10, 0x20 }));
    cache.record_add(record_encode(&buffer, 2, .truncated, &.{0x30}));

    const keys = [_]cpu_wire.CountKey{
        .{ .stack_hash = 1, .tgid = 7, .generation = 0 },
        .{ .stack_hash = 2, .tgid = 7, .generation = 0 },
        .{ .stack_hash = 3, .tgid = 7, .generation = 0 }, // No frames for this one.
    };
    const values = [_]u64{ 5, 9, 4 };
    var target: [3]Stack = undefined;
    const built = stacks_build(&target, &keys, &values, &cache);

    try testing.expectEqual(@as(usize, 2), built.stacks.len);
    try testing.expectEqual(@as(u64, 14), built.samples);
    try testing.expectEqual(@as(u64, 4), built.frames_missing);
    try testing.expectEqual(@as(u64, 9), built.stacks[0].samples); // Most samples first.
    try testing.expectEqual(StopReason.truncated, built.stacks[0].stop);
    try testing.expectEqualSlices(u64, &.{ 0x10, 0x20 }, built.stacks[1].user);
    try testing.expect(built.stacks[1].leaf_is_return);
    try testing.expectEqual(@as(u64, 5), built.stops[@intFromEnum(StopReason.end)]);
    try testing.expectEqual(@as(u64, 9), built.stops[@intFromEnum(StopReason.truncated)]);

    var stops_sum: u64 = 0;
    for (built.stops) |samples| stops_sum += samples;
    try testing.expectEqual(built.samples, stops_sum);
}

test "no counts make an empty window" {
    var cache: frame_cache.FrameCache = undefined;
    try cache.init(testing.allocator, .{ .stacks_max = 1, .frames_max = cpu_wire.frames_max });
    defer cache.deinit(testing.allocator);
    var target: [1]Stack = undefined;
    const built = stacks_build(&target, &.{}, &.{}, &cache);
    try testing.expectEqual(@as(usize, 0), built.stacks.len);
    try testing.expectEqual(@as(u64, 0), built.samples);
}
