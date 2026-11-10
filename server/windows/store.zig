//! The reports of each target, a ring of windows per target.

const std = @import("std");
const protocol = @import("shared").protocol;
const WindowRing = @import("window_ring.zig").WindowRing;
const log = @import("../log.zig").server;

const assert = std.debug.assert;
const Message = protocol.Message;

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
        finished: bool,
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

    pub fn target_add(
        store: *Store,
        gpa: std.mem.Allocator,
        pid: u32,
    ) error{ TargetsFull, OutOfMemory }!TargetId {
        assert(pid > 0);
        assert(store.count <= store.targets.len);
        if (store.count == store.targets.len) {
            const oldest = store.finished_oldest() orelse return error.TargetsFull;
            store.target_remove(gpa, oldest) catch unreachable;
            log.info("finished target dropped to make room: its windows are gone", .{
                .target = oldest,
                .targets_max = store.targets.len,
            });
        }

        const target = &store.targets[store.count];
        try target.ring.init(gpa, store.ring_options);
        target.id = store.next_id;
        target.pid = pid;
        target.windows_rejected = 0;
        target.finished = false;

        store.count += 1;
        store.next_id += 1;
        return target.id;
    }

    pub fn target_finish(store: *Store, id: TargetId) error{TargetUnknown}!void {
        const target = store.target_find(id) orelse return error.TargetUnknown;
        target.finished = true;
    }

    pub fn target_remove(
        store: *Store,
        gpa: std.mem.Allocator,
        id: TargetId,
    ) error{TargetUnknown}!void {
        const target = store.target_find(id) orelse return error.TargetUnknown;
        target.ring.deinit(gpa);
        store.count -= 1;
        target.* = store.targets[store.count];
    }

    fn finished_oldest(store: *const Store) ?TargetId {
        var oldest: ?TargetId = null;
        for (store.targets[0..store.count]) |target| {
            if (!target.finished) continue;
            if (oldest == null or target.id < oldest.?) oldest = target.id;
        }
        return oldest;
    }

    pub fn target_find(store: *Store, id: TargetId) ?*Target {
        for (store.targets[0..store.count]) |*target| {
            if (target.id == id) return target;
        }
        return null;
    }

    pub fn ingest(
        store: *Store,
        id: TargetId,
        message: *const Message,
    ) error{ TargetUnknown, WindowTooLarge }!void {
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

fn store_test(targets_max: u32) !Store {
    var store: Store = undefined;
    try store.init(testing.allocator, .{
        .targets_max = targets_max,
        .ring = .{ .windows_max = 2, .window_bytes_max = 1024 },
    });
    return store;
}

test "each target has its own windows" {
    const stacks = stacks_test(&.{1});
    var store = try store_test(4);
    defer store.deinit(testing.allocator);

    const first = try store.target_add(testing.allocator, 100);
    const second = try store.target_add(testing.allocator, 200);
    try testing.expect(first != second);

    try store.ingest(first, &message_test(1, &stacks));
    try store.ingest(first, &message_test(2, &stacks));
    try store.ingest(second, &message_test(7, &stacks));

    const first_ring = &store.target_find(first).?.ring;
    const second_ring = &store.target_find(second).?.ring;
    try testing.expectEqual(@as(u32, 2), first_ring.count);
    try testing.expectEqual(@as(u32, 1), second_ring.count);
    try testing.expectEqual(@as(u64, 2), first_ring.window_get(0).start_unix_ns);
    try testing.expectEqual(@as(u64, 7), second_ring.window_get(0).start_unix_ns);
}

test "an unknown target, a full store and a message too big are errors, counted" {
    const small = stacks_test(&.{1});
    const big_frames = [_]u64{0} ** 200;
    const big = stacks_test(&big_frames);

    var store = try store_test(1);
    defer store.deinit(testing.allocator);

    try testing.expectError(error.TargetUnknown, store.ingest(99, &message_test(1, &small)));

    const id = try store.target_add(testing.allocator, 100);
    try testing.expectError(error.TargetsFull, store.target_add(testing.allocator, 200));

    try testing.expectError(error.WindowTooLarge, store.ingest(id, &message_test(1, &big)));
    try testing.expectEqual(@as(u64, 1), store.target_find(id).?.windows_rejected);
    try store.ingest(id, &message_test(2, &small));
}

test "a full store makes room by dropping its oldest finished target, never a running one" {
    const stacks = stacks_test(&.{1});
    var store = try store_test(2);
    defer store.deinit(testing.allocator);

    const first = try store.target_add(testing.allocator, 100);
    const second = try store.target_add(testing.allocator, 200);
    try store.ingest(second, &message_test(5, &stacks));
    try testing.expectError(error.TargetsFull, store.target_add(testing.allocator, 300));

    try store.target_finish(second);
    try store.target_finish(first);
    const third = try store.target_add(testing.allocator, 300);
    try testing.expect(store.target_find(first) == null);
    try testing.expectEqual(@as(u32, 1), store.target_find(second).?.ring.count);
    try testing.expectEqual(@as(u32, 300), store.target_find(third).?.pid);
    try testing.expect(third != first and third != second);
    try testing.expectError(error.TargetUnknown, store.ingest(first, &message_test(6, &stacks)));

    try store.target_remove(testing.allocator, second);
    try testing.expectError(error.TargetUnknown, store.target_remove(testing.allocator, second));
    try testing.expectEqual(@as(u32, 1), store.count);
}
