//! The agent's second loop, next to `profile`: a look at every process of the machine at once,
//! then one every interval, until a cancel or the duration. All on the calling thread.

const std = @import("std");
const Cancel = @import("os/cancel.zig").Cancel;
const log = @import("log.zig").agent;
const procs = @import("processes/process.zig");
const timer = @import("os/timer.zig");
const poll_file = @import("os/poll.zig");
const Looks = @import("processes/process.zig").Looks;

pub const Frame = procs.Frame;

pub const StopReason = enum { duration, cancelled };

pub const Options = struct {
    /// Milliseconds between two looks. The CPU of each process is measured over this.
    interval_ms: u32,
    /// Seconds to watch. 0 watches until the watch is cancelled.
    duration_s: u32 = 0,
    /// Lets another thread, or a signal handler, stop the watch. Null: only the duration or a
    /// failing callback stops it.
    cancel: ?*const Cancel = null,
};

const Source = enum { look_timer, cancel };
const Poll = poll_file.Poll(Source);

/// Watches the processes of the machine, and says why it stopped.
///
///     fn on_frame(state: *State, frame: *const Frame) !void
///
/// runs once per look. The frame is valid only during the call. The first has no
/// `cpu_percent`: CPU is measured against the look before.
pub fn watch_processes(
    gpa: std.mem.Allocator,
    options: Options,
    context: anytype,
    comptime on_frame: anytype,
) !StopReason {
    comptime callback_check(@TypeOf(context), on_frame);
    errdefer |err| log.err("watching processes failed", .{ .cause = err });
    if (options.interval_ms == 0) return error.InvalidInterval;

    var look_timer = try timer.Timer.init(options.interval_ms);
    defer look_timer.deinit();
    var poll = Poll.init(.init(.{
        .look_timer = look_timer.fd,
        .cancel = if (options.cancel) |cancel| cancel.fd else -1,
    }));
    const deadline_ns = timer.deadline_from(options.duration_s);
    log.info("watching processes", .{
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
    });

    var looks = Looks.init();
    defer looks.deinit(gpa);

    try look_deliver(&looks, gpa, context, on_frame);
    var show: u64 = 1;

    // Every round waits on poll, so the loop cannot spin. A cancel wins over the duration.
    const stop: StopReason = while (true) {
        const ready = try poll.wait(timer.timeout_ms(deadline_ns));
        if (ready.contains(.cancel)) break .cancelled;
        if (deadline_ns) |deadline| {
            if (timer.monotonic_ns() >= deadline) break .duration;
        }
        if (ready.contains(.look_timer)) {
            // Missed periods are not made up: the next frame's interval_ns says how long it was.
            _ = try look_timer.expirations_read();
            try look_deliver(&looks, gpa, context, on_frame);
            show += 1;
        }
    };

    log.info("watching processes stopped", .{ .reason = stop, .looks = show });
    return stop;
}

/// For now an empty look: the steps after this fill it from /proc.
fn look_deliver(
    looks: *Looks,
    gpa: std.mem.Allocator,
    context: anytype,
    comptime on_frame: anytype,
) !void {
    const frame = try looks.take(gpa);

    // The callback may return void or an error union; an error stops the watch.
    const Return = @typeInfo(@TypeOf(on_frame)).@"fn".return_type.?;
    if (@typeInfo(Return) == .error_union) {
        try on_frame(context, &frame);
    } else {
        on_frame(context, &frame);
    }
}

/// Clear compile errors for the easy mistakes, instead of a long error from deep inside.
fn callback_check(comptime Context: type, comptime on_frame: anytype) void {
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |pointer| pointer,
        else => @compileError("watch: `context` must be a pointer to your state, like &state"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("watch: `context` must be a mutable pointer to one value, like &state");
    }

    const callback = switch (@typeInfo(@TypeOf(on_frame))) {
        .@"fn" => |callback| callback,
        else => @compileError("watch: `on_frame` must be a function"),
    };
    const signature = "watch: `on_frame` must be `fn (" ++ @typeName(Context) ++
        ", *const Frame) !void`";
    if (callback.params.len != 2) @compileError(signature);
    if (callback.params[0].type.? != Context) @compileError(signature);
    if (callback.params[1].type.? != *const Frame) @compileError(signature);
}

// --- tests ---
const testing = std.testing;
const process = @import("os/process.zig");

const Counter = struct {
    looks: u32 = 0,
    fn on_frame(counter: *Counter, frame: *const Frame) void {
        _ = frame;
        counter.looks += 1;
    }
};

test "the first look comes at once, then one per interval, until the duration" {
    var counter = Counter{};
    const reason = try watch_processes(testing.allocator, .{
        .interval_ms = 300,
        .duration_s = 1,
    }, &counter, Counter.on_frame);
    try testing.expectEqual(StopReason.duration, reason);
    // At 0, 300, 600 and 900 ms; the 4th can lose the race with the deadline.
    try testing.expect(counter.looks >= 3 and counter.looks <= 4);
}

test "a cancel stops the watch after the first look" {
    var cancel = try Cancel.init();
    defer cancel.deinit();
    cancel.trigger();

    var counter = Counter{};
    const reason = try watch_processes(testing.allocator, .{
        .interval_ms = 1000,
        .cancel = &cancel,
    }, &counter, Counter.on_frame);
    try testing.expectEqual(StopReason.cancelled, reason);
    try testing.expectEqual(@as(u32, 1), counter.looks);
}

const Busy = struct {
    frames: u32 = 0,
    first_cpu: ?f32 = 0,
    own_cpu: ?f32 = null,
    own_memory: u64 = 0,

    fn on_frame(busy: *Busy, frame: *const Frame) void {
        busy.frames += 1;
        for (frame.processes) |info| {
            if (info.pid != process.current_pid()) continue;
            if (busy.frames == 1) busy.first_cpu = info.cpu_percent;
            busy.own_cpu = info.cpu_percent;
            busy.own_memory = info.memory_bytes;
        }
        // Work until the next look, so it sees this process on the CPU.
        const until = timer.monotonic_ns() + 150 * std.time.ns_per_ms;
        while (timer.monotonic_ns() < until) {}
    }
};
