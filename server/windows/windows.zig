//! The windows layer.

const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("shared").protocol;
const os = @import("../os/os.zig");
const store_file = @import("store.zig");
const log = @import("../log.zig").server;

const Message = protocol.Message;

pub const TargetId = store_file.TargetId;

pub const Query = struct {
    target: TargetId,
    from_unix_ns: u64 = 0,
    to_unix_ns: u64 = std.math.maxInt(u64),
};

pub const Options = struct {
    targets_max: u32 = 16,
    windows_per_target_max: u32 = 120,
    window_bytes_max: u32 = 128 * 1024,
};

pub const Copied = struct {
    windows: []Message,
    rejected: u64,
};

pub const Windows = struct {
    lock: os.Lock,
    store: store_file.Store,

    pub fn init(windows: *Windows, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.window_bytes_max > 0 and options.window_bytes_max % 8 == 0);
        windows.lock = .{};
        try windows.store.init(gpa, .{
            .targets_max = options.targets_max,
            .ring = .{
                .windows_max = options.windows_per_target_max,
                .window_bytes_max = options.window_bytes_max,
            },
        });
    }

    pub fn deinit(windows: *Windows, gpa: std.mem.Allocator) void {
        windows.store.deinit(gpa);
        windows.* = undefined;
    }

    pub fn add(windows: *Windows, gpa: std.mem.Allocator, pid: u32) !TargetId {
        windows.lock.lock();
        defer windows.lock.unlock();
        const target = windows.store.target_add(gpa, pid) catch |err| {
            log.warn("process not tracked", .{
                .pid = pid,
                .targets_max = windows.store.targets.len,
                .cause = err,
            });
            return err;
        };
        log.debug("target added", .{ .target = target, .pid = pid });
        return target;
    }

    pub fn finish(windows: *Windows, target: TargetId) !void {
        windows.lock.lock();
        defer windows.lock.unlock();
        try windows.store.target_finish(target);
        log.debug("target finished", .{ .target = target });
    }

    pub fn put(windows: *Windows, target: TargetId, message: *const Message) !void {
        windows.lock.lock();
        defer windows.lock.unlock();
        windows.store.ingest(target, message) catch |err| {
            if (err == error.WindowTooLarge) windows.lost_log(target);
            return err;
        };
    }

    pub fn copy(windows: *Windows, arena: std.mem.Allocator, query: Query) !Copied {
        windows.lock.lock();
        defer windows.lock.unlock();
        const target = windows.store.target_find(query.target) orelse return error.TargetUnknown;
        const ring = &target.ring;

        var count: usize = 0;
        for (0..ring.count) |age| {
            if (overlaps(ring.window_get(@intCast(age)), query)) count += 1;
        }
        const copied = try arena.alloc(Message, count);
        var filled: usize = 0;
        var age: u32 = ring.count;
        while (age > 0) {
            age -= 1;
            const window = ring.window_get(age);
            if (!overlaps(window, query)) continue;
            copied[filled] = try window.clone(arena);
            filled += 1;
        }
        assert(filled == count);
        return .{ .windows = copied, .rejected = target.windows_rejected };
    }

    fn lost_log(windows: *Windows, target: TargetId) void {
        if (windows.store.target_find(target).?.windows_rejected != 1) return;
        log.warn("window too big to keep: its samples are lost", .{
            .target = target,
            .window_kib_max = windows.store.ring_options.window_bytes_max / 1024,
        });
    }
};

fn overlaps(window: *const Message, query: Query) bool {
    const end_unix_ns = window.start_unix_ns +| window.duration_ns;
    return window.start_unix_ns < query.to_unix_ns and end_unix_ns > query.from_unix_ns;
}

const testing = std.testing;

test {
    _ = store_file;
    _ = @import("window_ring.zig");
}

fn window_test(start_unix_ns: u64, samples: u64) Message {
    const stacks = struct {
        const one = [_]Message.Stack{
            .{ .samples = 1, .user = &.{1}, .kernel = &.{}, .complete = true },
        };
    };
    return .{
        .start_unix_ns = start_unix_ns,
        .duration_ns = 100,
        .pid = 1,
        .sample_hz = 99,
        .samples = samples,
        .samples_lost = 0,
        .regions = &.{},
        .stacks = &stacks.one,
    };
}

test "a target's windows are kept, copied by time range, and an unknown one is refused" {
    var windows: Windows = undefined;
    try windows.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 4,
        .window_bytes_max = 1024,
    });
    defer windows.deinit(testing.allocator);

    try testing.expectError(error.TargetUnknown, windows.put(1, &window_test(100, 3)));
    const target = try windows.add(testing.allocator, 42);
    try windows.put(target, &window_test(100, 3));
    try windows.put(target, &window_test(200, 4));
    try testing.expectError(error.TargetsFull, windows.add(testing.allocator, 43));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const all = try windows.copy(arena.allocator(), .{ .target = target });
    try testing.expectEqual(@as(usize, 2), all.windows.len);
    try testing.expectEqual(@as(u64, 3), all.windows[0].samples);
    const late = try windows.copy(arena.allocator(), .{ .target = target, .from_unix_ns = 250 });
    try testing.expectEqual(@as(usize, 1), late.windows.len);
    const unknown = windows.copy(arena.allocator(), .{ .target = 999 });
    try testing.expectError(error.TargetUnknown, unknown);

    try windows.finish(target);
    _ = try windows.add(testing.allocator, 43);
}
