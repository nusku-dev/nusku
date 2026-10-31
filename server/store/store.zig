//! Where the server keeps what the agents report: one ring of windows per target, found by
//! id. Single-threaded: whoever shares a store between threads puts a lock around it.

const std = @import("std");
const agent = @import("agent");
const WindowRing = @import("window_ring.zig").WindowRing;

const assert = std.debug.assert;
const Message = agent.Message;

pub const TargetId = u64;

pub const Store = struct {
    targets: []Target,
    count: u32,
    next_id: TargetId,
    ring_options: WindowRing.Options,

    pub const Target = struct {
        id: TargetId,
        pid: u32,
        ring: WindowRing,
        windows_rejected: u64,
    };

    pub const Options = struct {
        targets_max: u32,
        ring: WindowRing.Options,
    };

    pub fn init(store: *Store, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.targets_max > 0);
        const targets = try gpa.alloc(Target, options.targets_max);
        store.* = .{
            .targets = targets,
            .count = 0,
            .next_id = 1,
            .ring_options = options.ring,
        };
    }

    /// Registers a process and reserves its ring. Not for the hot path: this allocates.
    pub fn target_add(store: *Store, gpa: std.mem.Allocator, pid: u32) error{ TargetsFull, OutOfMemory }!TargetId {
        assert(pid > 0);
        assert(store.count <= store.targets.len);
        if (store.count == store.targets.len) return error.TargetsFull;

        const target = &store.targets[store.count];
        try target.ring.init(gpa, store.ring_options);
        target.id = store.next_id;
        target.pid = pid;
        target.windows_rejected = 0;

        store.count += 1;
        store.next_id += 1;
        return target.id;
    }

    /// Null for an id that was never handed out. A linear scan: `targets_max` is small.
    pub fn target_find(store: *Store, id: TargetId) ?*Target {
        for (store.targets[0..store.count]) |*target| {
            if (target.id == id) return target;
        }
        return null;
    }

    /// Keeps a copy of the message as the target's newest window. Does not allocate.
    pub fn ingest(store: *Store, id: TargetId, message: *const Message) error{ TargetUnknown, WindowTooLarge }!void {
        const target = store.target_find(id) orelse return error.TargetUnknown;
        target.ring.push(message) catch |err| {
            target.windows_rejected += 1;
            return err;
        };
    }

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        for (store.targets[0..store.count]) |*target| target.ring.deinit(gpa);
        gpa.free(store.targets);
        store.* = undefined;
    }
};

// ------------------------------------------------------------------------------------- tests

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

fn store_test(targets_max: u32) !Store {
    var store: Store = undefined;
    try store.init(testing.allocator, .{
        .targets_max = targets_max,
        .ring = .{ .windows_max = 2, .window_bytes_max = 1024 },
    });
    return store;
}

test "each target has its own windows" {
    const stacks = [_]Message.Stack{.{ .samples = 1, .user = &.{1}, .kernel = &.{}, .complete = true }};
    var store = try store_test(4);
    defer store.deinit(testing.allocator);

    const first = try store.target_add(testing.allocator, 100);
    const second = try store.target_add(testing.allocator, 200);
    try testing.expect(first != second);

    try store.ingest(first, &message_test(1, &stacks));
    try store.ingest(first, &message_test(2, &stacks));
    try store.ingest(second, &message_test(7, &stacks));

    try testing.expectEqual(@as(u32, 2), store.target_find(first).?.ring.count);
    try testing.expectEqual(@as(u32, 1), store.target_find(second).?.ring.count);
    try testing.expectEqual(@as(u64, 2), store.target_find(first).?.ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u64, 7), store.target_find(second).?.ring.window_get(0).start_unix_ns);
}

test "an unknown target, a full store and a message too big are errors, counted" {
    const small = [_]Message.Stack{.{ .samples = 1, .user = &.{1}, .kernel = &.{}, .complete = true }};
    const big_frames = [_]u64{0} ** 200; // 1600 bytes, more than a window of 1024
    const big = [_]Message.Stack{.{ .samples = 1, .user = &big_frames, .kernel = &.{}, .complete = true }};

    var store = try store_test(1);
    defer store.deinit(testing.allocator);

    try testing.expectError(error.TargetUnknown, store.ingest(99, &message_test(1, &small)));

    const id = try store.target_add(testing.allocator, 100);
    try testing.expectError(error.TargetsFull, store.target_add(testing.allocator, 200));

    try testing.expectError(error.WindowTooLarge, store.ingest(id, &message_test(1, &big)));
    try testing.expectEqual(@as(u64, 1), store.target_find(id).?.windows_rejected);
    try store.ingest(id, &message_test(2, &small)); // still works afterwards
}
