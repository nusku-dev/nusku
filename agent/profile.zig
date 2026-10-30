//! Runs a profile from start to finish: the agent's main loop.
//!
//! The loop runs at its own pace, not in reaction to what the target does: a tick timer drains
//! the kernel's buffers, a report timer hands out a window, and the target's exit or a cancel
//! ends the run. Everything happens on the calling thread, so there are no locks.

const std = @import("std");
const assert = std.debug.assert;
const timer = @import("os/timer.zig");
const process = @import("os/process.zig");
const PidFd = @import("os/pidfd.zig").PidFd;
const Cancel = @import("os/cancel.zig").Cancel;
const poll_file = @import("os/poll.zig");
const session_file = @import("session.zig");

const Timer = timer.Timer;
const Poll = poll_file.Poll;
const Session = session_file.Session;
const Metric = session_file.Metric;
const Report = session_file.Report;

pub const StopReason = enum { duration, target_exited, cancelled };

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(Metric),
    /// Milliseconds between reports.
    interval_ms: u32,
    /// Seconds to run. 0 runs until the target exits or the run is cancelled.
    duration_s: u32,
    /// Lets another thread stop the run. Null: the run cannot be cancelled.
    cancel: ?*const Cancel = null,
};

/// How often the kernel's ring buffer is drained between reports. Sketch: at 99 Hz on 64 CPUs
/// a tick sees at most 634 samples, and only the new stacks among them take ring space, so the
/// ring (cpu_wire.records_bytes) cannot fill between two ticks.
const tick_ms_max = 100;

/// Profiles one process from start to finish, and returns why it stopped.
///
/// `context` is a pointer to the caller's state, and `on_report` a function that takes it first:
///
///     fn on_report(state: *State, report: *const Report) !void
///
/// - Blocks the calling thread. `on_report` runs on that thread, once per `interval_ms`, and
///   once more with the last, partial window.
/// - The report is valid only during the call. Copy whatever must outlive it.
/// - `on_report` returns void, or an error that stops the run: `profile` then releases what it
///   loaded into the kernel and returns that error.
/// - To stop the run from another thread, pass a `Cancel` and `trigger()` it.
/// - Needs root, or CAP_BPF and CAP_PERFMON. CAP_SYSLOG is needed too for the kernel's text
///   address in `Report.kernel`; without it that is null and kernel frames cannot be placed.
pub fn profile(
    gpa: std.mem.Allocator,
    options: Options,
    context: anytype,
    comptime on_report: anytype,
) !StopReason {
    comptime callback_check(@TypeOf(context), on_report);
    if (options.interval_ms == 0) return error.InvalidInterval;
    if (options.metrics.count() == 0) return error.NoMetrics;
    if (!process.pid_valid(options.pid)) return error.InvalidPid;

    var pidfd = try PidFd.init(options.pid);
    defer pidfd.deinit();

    // On the heap: it is large, and the collectors keep pointers into it.
    const session = try gpa.create(Session);
    defer gpa.destroy(session);

    try session.init(gpa, .{ .pid = options.pid, .metrics = options.metrics });
    defer session.deinit(gpa);

    // Armed only now: loading the program and building the tables can take longer than an
    // interval, and the first window must be a whole one, counted from when sampling began.
    var report_timer = try Timer.init(options.interval_ms);
    defer report_timer.deinit();

    var tick_timer = try Timer.init(@min(tick_ms_max, options.interval_ms));
    defer tick_timer.deinit();

    const deadline_ns: ?u64 = if (options.duration_s == 0)
        null
    else
        timer.monotonic_ns() + @as(u64, options.duration_s) * std.time.ns_per_s;

    var poll = Poll.init(.init(.{
        .report_timer = report_timer.fd,
        .tick_timer = tick_timer.fd,
        .target_exit = pidfd.fd,
        .cancel = if (options.cancel) |cancel| cancel.fd else -1,
    }));

    // An event loop: it does not count its rounds. It ends only by a stop condition below,
    // and every round waits on poll, so it cannot spin.
    while (true) {
        const ready = try poll.wait(timeout_ms(deadline_ns));

        if (ready.contains(.tick_timer)) {
            _ = try tick_timer.expirations_read();
            try session.tick();
        }
        var reported = false;
        if (ready.contains(.report_timer)) {
            // Missed periods are not made up: one late report covers them, its duration says so.
            _ = try report_timer.expirations_read();
            try report_deliver(gpa, session, context, on_report);
            reported = true;
        }

        const stop = stop_reason(ready, deadline_ns) orelse continue;
        // The last, partial window.
        if (!reported) try report_deliver(gpa, session, context, on_report);
        return stop;
    }
}

/// Why the run must stop now, or null to go on. A cancel wins over the target's exit, which
/// wins over the duration: the most specific reason is reported.
fn stop_reason(ready: poll_file.Ready, deadline_ns: ?u64) ?StopReason {
    if (ready.contains(.cancel)) return .cancelled;
    if (ready.contains(.target_exit)) return .target_exited;
    if (deadline_ns) |deadline| {
        if (timer.monotonic_ns() >= deadline) return .duration;
    }
    return null;
}

/// How long poll may wait: until the deadline, so it wakes for it even if nothing is ready.
fn timeout_ms(deadline_ns: ?u64) i32 {
    const deadline = deadline_ns orelse return -1;
    const now = timer.monotonic_ns();
    if (now >= deadline) return 0;
    // divCeil fails only on a zero divisor.
    const remaining_ms = std.math.divCeil(u64, deadline - now, std.time.ns_per_ms) catch
        unreachable;
    return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
}

fn report_deliver(
    gpa: std.mem.Allocator,
    session: *Session,
    context: anytype,
    comptime on_report: anytype,
) !void {
    const report = try session.report(gpa);
    // The callback may return void or an error union; an error stops the run.
    const Return = @typeInfo(@TypeOf(on_report)).@"fn".return_type.?;
    if (@typeInfo(Return) == .error_union) {
        try on_report(context, &report);
    } else {
        on_report(context, &report);
    }
}

/// Clear compile errors for the easy mistakes, instead of a long error from deep inside.
fn callback_check(comptime Context: type, comptime on_report: anytype) void {
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |pointer| pointer,
        else => @compileError("profile: `context` must be a pointer to your state, like &state"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("profile: `context` must be a mutable pointer to one value, like &state");
    }

    const callback = switch (@typeInfo(@TypeOf(on_report))) {
        .@"fn" => |callback| callback,
        else => @compileError("profile: `on_report` must be a function"),
    };
    const signature = "profile: `on_report` must be `fn (" ++ @typeName(Context) ++
        ", *const Report) !void`";
    if (callback.params.len != 2) @compileError(signature);
    if (callback.params[0].type.? != Context) @compileError(signature);
    if (callback.params[1].type.? != *const Report) @compileError(signature);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("testing/process.zig");
const Set = std.EnumSet(Metric);

const Counter = struct {
    reports: u32 = 0,
    samples: u64 = 0,

    fn on_report(counter: *Counter, report: *const Report) void {
        counter.reports += 1;
        if (report.cpu) |cpu| counter.samples += cpu.samples;
    }
};

test "the timeout reaches the deadline, and none means wait for ever" {
    try testing.expectEqual(@as(i32, -1), timeout_ms(null));
    try testing.expectEqual(@as(i32, 0), timeout_ms(0));
    const timeout = timeout_ms(timer.monotonic_ns() + 50 * std.time.ns_per_ms);
    try testing.expect(timeout > 0);
    try testing.expect(timeout <= 50);
}

test "stops when the target exits and reports its CPU use (needs root, skipped otherwise)" {
    const child = try child_process.burner_spawn(700);
    defer child_process.child_reap(child);

    var counter = Counter{};
    const started_ns = timer.monotonic_ns();
    const reason = profile(testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 200,
        .duration_s = 0,
    }, &counter, Counter.on_report) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const elapsed_ms = (timer.monotonic_ns() - started_ns) / std.time.ns_per_ms;

    std.debug.print("profile: {d} reports, {d} samples, {d} ms\n", .{
        counter.reports, counter.samples, elapsed_ms,
    });
    try testing.expectEqual(StopReason.target_exited, reason);
    try testing.expect(elapsed_ms < 1500);
    // Reports every 200 ms from when sampling began (after the start-up), then one at the exit:
    // at least one whole interval and the last window fit in the child's 700 ms.
    try testing.expect(counter.reports >= 2);
    try testing.expect(counter.samples >= 20); // About 69 for 700 ms at 99 Hz.
}

test "stops at the duration while the target keeps running (needs root, skipped otherwise)" {
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    var counter = Counter{};
    const started_ns = timer.monotonic_ns();
    const reason = profile(testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 1,
    }, &counter, Counter.on_report) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const elapsed_ms = (timer.monotonic_ns() - started_ns) / std.time.ns_per_ms;

    try testing.expectEqual(StopReason.duration, reason);
    try testing.expect(elapsed_ms >= 1000);
    try testing.expect(elapsed_ms < 1500);
    try testing.expect(counter.reports >= 3);
    try testing.expect(counter.reports <= 5);
    try testing.expect(counter.samples >= 40);
}

test "a cancel triggered before the run stops it at once (needs root, skipped otherwise)" {
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    var cancel = try Cancel.init();
    defer cancel.deinit();
    cancel.trigger();

    var counter = Counter{};
    const started_ns = timer.monotonic_ns();
    const reason = profile(testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 1000,
        .duration_s = 0,
        .cancel = &cancel,
    }, &counter, Counter.on_report) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try testing.expectEqual(StopReason.cancelled, reason);
    try testing.expectEqual(@as(u32, 1), counter.reports); // Just the last window.
    try testing.expect(timer.monotonic_ns() - started_ns < 500 * std.time.ns_per_ms);
}
