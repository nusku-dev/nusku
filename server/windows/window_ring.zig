//! The last windows of one target.

const std = @import("std");
const protocol = @import("shared").protocol;

const assert = std.debug.assert;
const Message = protocol.Message;

pub const WindowRing = struct {
    bytes: []align(8) u8,
    messages: []Message,
    window_bytes_max: u32,
    head: u32,
    count: u32,

    pub const Options = struct {
        windows_max: u32,
        window_bytes_max: u32,
    };

    pub fn init(ring: *WindowRing, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.windows_max > 0);
        assert(options.window_bytes_max > 0);
        assert(options.window_bytes_max % 8 == 0);

        const total = @as(usize, options.windows_max) * options.window_bytes_max;
        const bytes = try gpa.alignedAlloc(u8, .@"8", total);
        errdefer gpa.free(bytes);

        const messages = try gpa.alloc(Message, options.windows_max);
        ring.* = .{
            .bytes = bytes,
            .messages = messages,
            .window_bytes_max = options.window_bytes_max,
            .head = 0,
            .count = 0,
        };
    }

    pub fn deinit(ring: *WindowRing, gpa: std.mem.Allocator) void {
        gpa.free(ring.messages);
        gpa.free(ring.bytes);
        ring.* = undefined;
    }

    pub fn push(ring: *WindowRing, message: *const Message) error{WindowTooLarge}!void {
        assert(ring.count <= ring.messages.len);
        assert(ring.head < ring.messages.len);

        if (ring.count == ring.messages.len) ring.count -= 1;

        const start = @as(usize, ring.head) * ring.window_bytes_max;
        const slot = ring.bytes[start..][0..ring.window_bytes_max];
        var fixed = std.heap.FixedBufferAllocator.init(slot);
        ring.messages[ring.head] = message.clone(fixed.allocator()) catch
            return error.WindowTooLarge;

        ring.head = (ring.head + 1) % @as(u32, @intCast(ring.messages.len));
        ring.count += 1;
    }

    pub fn window_get(ring: *const WindowRing, age: u32) *const Message {
        assert(age < ring.count);
        const len: u32 = @intCast(ring.messages.len);
        return &ring.messages[(ring.head + len - 1 - age) % len];
    }
};

const testing = std.testing;

fn stacks_test(user: []const u64) [1]Message.Stack {
    return .{.{ .samples = 1, .user = user, .kernel = &.{}, .complete = true }};
}

fn message_test(start_unix_ns: u64, stacks: []const Message.Stack) Message {
    return .{
        .start_unix_ns = start_unix_ns,
        .duration_ns = 1,
        .pid = 1,
        .sample_hz = 99,
        .samples = 1,
        .samples_lost = 0,
        .regions = &.{},
        .stacks = stacks,
    };
}

test "a full ring keeps the newest windows, oldest dropped" {
    const stacks = stacks_test(&.{ 1, 2, 3 });
    var ring: WindowRing = undefined;
    try ring.init(testing.allocator, .{ .windows_max = 3, .window_bytes_max = 4096 });
    defer ring.deinit(testing.allocator);

    for (1..6) |n| try ring.push(&message_test(@intCast(n), &stacks));

    try testing.expectEqual(@as(u32, 3), ring.count);
    try testing.expectEqual(@as(u64, 5), ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u64, 4), ring.window_get(1).start_unix_ns);
    try testing.expectEqual(@as(u64, 3), ring.window_get(2).start_unix_ns);
}

test "a message too big for a window is rejected and the ring stays consistent" {
    const small = stacks_test(&.{1});
    const big_frames = [_]u64{0} ** 1000;
    const big = stacks_test(&big_frames);

    var ring: WindowRing = undefined;
    try ring.init(testing.allocator, .{ .windows_max = 3, .window_bytes_max = 4096 });
    defer ring.deinit(testing.allocator);

    for (1..4) |n| try ring.push(&message_test(@intCast(n), &small));
    try testing.expectError(error.WindowTooLarge, ring.push(&message_test(9, &big)));

    try testing.expectEqual(@as(u32, 2), ring.count);
    try testing.expectEqual(@as(u64, 3), ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u64, 2), ring.window_get(1).start_unix_ns);

    try ring.push(&message_test(10, &small));
    try testing.expectEqual(@as(u64, 10), ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u32, 3), ring.count);
}
