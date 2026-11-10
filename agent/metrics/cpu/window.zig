//! One window of on-CPU samples.

const std = @import("std");
const assert = std.debug.assert;
const cpu_wire = @import("../kernel/shared/cpu_wire.zig");
const frame_cache = @import("frame_cache.zig");

pub const StopReason = cpu_wire.StopReason;
pub const stop_reason_count = cpu_wire.stop_reason_count;

pub const Stack = struct {
    samples: u64,
    user: []const u64,
    kernel: []const u64,
    stop: StopReason,
    leaf_is_return: bool,
    kernel_truncated: bool,
};

pub const Loss = struct {
    ring_full: u64 = 0,
    counts_full: u64 = 0,
    frames_missing: u64 = 0,
    records_malformed: u64 = 0,
    walks_abandoned: u64 = 0,
};

pub const Window = struct {
    sample_hz: u32,
    samples: u64,
    stacks: []const Stack,
    stops: [stop_reason_count]u64,
    loss: Loss,
};

pub const Built = struct {
    stacks: []Stack,
    samples: u64,
    stops: [stop_reason_count]u64,
    frames_missing: u64,
};

/// The stacks refer to the cache's frames, so they are valid until the cache's next epoch_advance.
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
        assert(samples > 0);
        const record = cache.find(.{ .hash = key.stack_hash, .tgid = key.tgid }) orelse {
            built.frames_missing += samples;
            continue;
        };
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
        .{ .stack_hash = 3, .tgid = 7, .generation = 0 },
    };
    const values = [_]u64{ 5, 9, 4 };
    var target: [3]Stack = undefined;
    const built = stacks_build(&target, &keys, &values, &cache);

    try testing.expectEqual(@as(usize, 2), built.stacks.len);
    try testing.expectEqual(@as(u64, 14), built.samples);
    try testing.expectEqual(@as(u64, 4), built.frames_missing);
    try testing.expectEqual(@as(u64, 9), built.stacks[0].samples);
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
