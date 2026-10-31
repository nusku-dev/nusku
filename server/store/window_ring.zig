//! The last windows of one target, in memory reserved at init. `push` never allocates: it
//! copies the message into the slot's own bytes, and fails if the message does not fit.

const std = @import("std");
const agent = @import("agent");

const assert = std.debug.assert;
const Message = agent.Message;

pub const WindowRing = struct {
    /// One `window_bytes_max` slice per window; the message in slot `i` lives in slice `i`.
    bytes: []align(8) u8,
    messages: []Message,
    window_bytes_max: u32,
    /// The slot the next push writes. The newest window is the one before it.
    head: u32,
    count: u32,

    pub const Options = struct {
        windows_max: u32,
        /// Bytes one window may take, multiple of 8: it bounds the memory of the ring.
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

    /// Keeps a copy of `message` as the newest window; when the ring is full, the oldest
    /// window goes. A message that does not fit in one window is rejected, and the oldest
    /// window is still gone then, because its slot was the one being written.
    pub fn push(ring: *WindowRing, message: *const Message) error{WindowTooLarge}!void {
        assert(ring.count <= ring.messages.len);
        assert(ring.head < ring.messages.len);

        // A full ring writes over its oldest window, which sits at `head`: drop it first,
        // so a failed copy leaves the ring consistent.
        if (ring.count == ring.messages.len) ring.count -= 1;

        const start = @as(usize, ring.head) * ring.window_bytes_max;
        var fixed = std.heap.FixedBufferAllocator.init(ring.bytes[start..][0..ring.window_bytes_max]);
        ring.messages[ring.head] = message.clone(fixed.allocator()) catch return error.WindowTooLarge;

        ring.head = (ring.head + 1) % @as(u32, @intCast(ring.messages.len));
        ring.count += 1;
    }

    /// The window `age` pushes ago: 0 is the newest.
    pub fn window_get(ring: *const WindowRing, age: u32) *const Message {
        assert(age < ring.count);
        const len: u32 = @intCast(ring.messages.len);
        return &ring.messages[(ring.head + len - 1 - age) % len];
    }
};

const testing = std.testing;

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
    const stacks = [_]Message.Stack{.{ .samples = 1, .user = &.{ 1, 2, 3 }, .kernel = &.{}, .complete = true }};
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
    const small = [_]Message.Stack{.{ .samples = 1, .user = &.{1}, .kernel = &.{}, .complete = true }};
    const big_frames = [_]u64{0} ** 1000; // 8000 bytes, more than a window
    const big = [_]Message.Stack{.{ .samples = 1, .user = &big_frames, .kernel = &.{}, .complete = true }};

    var ring: WindowRing = undefined;
    try ring.init(testing.allocator, .{ .windows_max = 3, .window_bytes_max = 4096 });
    defer ring.deinit(testing.allocator);

    for (1..4) |n| try ring.push(&message_test(@intCast(n), &small));
    try testing.expectError(error.WindowTooLarge, ring.push(&message_test(9, &big)));

    // The full ring lost its oldest window to the failed write; the others are intact.
    try testing.expectEqual(@as(u32, 2), ring.count);
    try testing.expectEqual(@as(u64, 3), ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u64, 2), ring.window_get(1).start_unix_ns);

    // And it keeps working.
    try ring.push(&message_test(10, &small));
    try testing.expectEqual(@as(u64, 10), ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u32, 3), ring.count);
}
