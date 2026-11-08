//! Every process of the machine, a frame at a time: the first at once, then one per interval.
//!
//!     var watch = try Watch.init(gpa, .{ .interval_ms = 1000 });
//!     defer watch.deinit();
//!     while (try watch.next()) |event| switch (event) { ... };
//!
//! No root needed: what /proc shows anyone.

const std = @import("std");
const protocol = @import("shared").protocol;
const Cancel = @import("os.zig").cancel.Cancel;
const timer = @import("os.zig").timer;
const poll_file = @import("os.zig").poll;
const Processes = @import("processes.zig").Processes;
const log = @import("log.zig").agent;

pub const Options = struct {
    /// Milliseconds between two frames. The CPU of each process is measured over this.
    interval_ms: u32 = 1000,
    /// 0: until `stop`.
    duration_s: u32 = 0,
};

/// Each is valid until the next `next`.
pub const Event = union(enum) {
    /// The first has no `cpu_percent`: CPU is measured against the frame before.
    frame: *const protocol.ProcessFrame,
    /// The last event: `next` returns null after it.
    stopped: protocol.WatchStop,
};

const Source = enum { look_timer, cancel };
const Poll = poll_file.Poll(Source);

pub const Watch = struct {
    gpa: std.mem.Allocator,
    processes: Processes,
    frame: protocol.ProcessFrame,
    cancel: Cancel,
    look_timer: timer.Timer,
    poll: Poll,
    deadline_ns: ?u64,
    phase: enum { first, watching, ended },
    frames: u64,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Watch {
        errdefer |err| log.err("watching processes failed", .{ .cause = err });
        if (options.interval_ms == 0) return error.InvalidInterval;
        var cancel = try Cancel.init();
        errdefer cancel.deinit();
        var look_timer = try timer.Timer.init(options.interval_ms);
        errdefer look_timer.deinit();
        log.info("watching processes", .{
            .interval_ms = options.interval_ms,
            .duration_s = options.duration_s,
        });
        return .{
            .gpa = gpa,
            .processes = Processes.init(),
            .frame = undefined,
            .cancel = cancel,
            .look_timer = look_timer,
            .poll = Poll.init(.init(.{ .look_timer = look_timer.fd, .cancel = cancel.fd })),
            .deadline_ns = timer.deadline_from(options.duration_s),
            .phase = .first,
            .frames = 0,
        };
    }

    pub fn deinit(watch: *Watch) void {
        watch.processes.deinit(watch.gpa);
        watch.look_timer.deinit();
        watch.cancel.deinit();
        watch.* = undefined;
    }

    /// The next event, waiting for it. Null after `.stopped`.
    pub fn next(watch: *Watch) !?Event {
        switch (watch.phase) {
            .ended => return null,
            .first => {
                watch.phase = .watching;
                return try watch.look();
            },
            .watching => {},
        }
        // Every round waits on poll, so the loop cannot spin. A cancel wins over the duration.
        while (true) {
            const ready = try watch.poll.wait(timer.timeout_ms(watch.deadline_ns));
            if (ready.contains(.cancel)) return watch.end(.cancelled);
            if (watch.deadline_ns) |deadline| {
                if (timer.monotonic_ns() >= deadline) return watch.end(.duration);
            }
            if (ready.contains(.look_timer)) {
                // Missed periods are not made up: the frame's interval_ns says how long it was.
                _ = try watch.look_timer.expirations_read();
                return try watch.look();
            }
        }
    }

    /// Ends the watch at its next wait. Safe from any thread, and from a signal handler.
    pub fn stop(watch: *const Watch) void {
        watch.cancel.trigger();
    }

    fn look(watch: *Watch) !Event {
        watch.frame = try watch.processes.take(watch.gpa);
        watch.frames += 1;
        return .{ .frame = &watch.frame };
    }

    fn end(watch: *Watch, reason: protocol.WatchStop) Event {
        watch.phase = .ended;
        log.info("watching processes stopped", .{ .reason = reason, .frames = watch.frames });
        return .{ .stopped = reason };
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// Frames until the end, and why it ended.
fn frames_count(watch: *Watch) !struct { u32, ?protocol.WatchStop } {
    var frames: u32 = 0;
    var stopped: ?protocol.WatchStop = null;
    while (try watch.next()) |event| switch (event) {
        .frame => frames += 1,
        .stopped => |reason| stopped = reason,
    };
    return .{ frames, stopped };
}

test "the first frame comes at once, then one per interval, until the duration" {
    var watch = try Watch.init(testing.allocator, .{ .interval_ms = 300, .duration_s = 1 });
    defer watch.deinit();
    const frames, const stopped = try frames_count(&watch);
    try testing.expectEqual(@as(?protocol.WatchStop, .duration), stopped);
    // At 0, 300, 600 and 900 ms; the 4th can lose the race with the deadline.
    try testing.expect(frames >= 3 and frames <= 4);
    try testing.expectEqual(@as(?Event, null), try watch.next());
}

test "stop ends the watch after the first frame" {
    var watch = try Watch.init(testing.allocator, .{});
    defer watch.deinit();
    watch.stop();
    const frames, const stopped = try frames_count(&watch);
    try testing.expectEqual(@as(?protocol.WatchStop, .cancelled), stopped);
    try testing.expectEqual(@as(u32, 1), frames);
}

test "a zero interval is refused" {
    try testing.expectError(error.InvalidInterval, Watch.init(testing.allocator, .{
        .interval_ms = 0,
    }));
}
