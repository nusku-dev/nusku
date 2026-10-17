const std = @import("std");
const s = @import("core/session.zig");
const cfg = @import("core/config.zig");
const sys = @import("core/sys.zig");
const po = @import("core/poll.zig");
const timer = @import("core/timer.zig");
const Cancel = @import("core/cancel.zig").Cancel;

const Poll = po.Poll;
const Session = s.Session;
const Report = s.Report;

pub const StopReason = enum { duration, target_exited, cancelled };

/// Profiles one process from start to finish and returns why it stopped.
///
/// `context` is a pointer to your own state, and `onReport` is a function that takes it first:
///
///     fn onReport(state: *MyState, report: *const Report) !void
///
/// - Blocks the calling thread. `onReport` runs on that same thread, once per
///   `options.interval_ms` and once more with the final partial window.
/// - The report is only valid during the call. Copy whatever must outlive it.
/// - `onReport` may return void, or an error to stop profiling. `profile` then releases
///   everything it loaded into the kernel and returns that error.
/// - To stop it from another thread, put a `Cancel` in `options.cancel` and call `trigger()`.
/// - Needs root, or CAP_BPF and CAP_PERFMON. CAP_SYSLOG is also needed for the kernel text
///   address in `Report.kernel`; without it that field is null and kernel frames cannot be placed.
pub fn profile(
    allocator: std.mem.Allocator,
    options: cfg.Options,
    context: anytype,
    comptime onReport: anytype,
) !StopReason {
    comptime checkCallback(@TypeOf(context), onReport);

    if (!sys.isValidPid(options.pid)) return error.InvalidPid;
    if (options.interval_ms == 0) return error.InvalidInterval;
    if (options.metrics.count() == 0) return error.NoMetrics;

    const pid_fd = try sys.openPidfd(options.pid);
    defer sys.fdClose(pid_fd);

    const timer_fd = try timer.createTimerfd();
    defer sys.fdClose(timer_fd);

    var session = try Session.init(allocator, options.metrics, options.pid);
    defer session.deinit();

    try timer.configTimer(options.interval_ms, timer_fd);

    const started = timer.nowMs();
    const deadline: ?u64 = if (options.duration_s == 0) null else started + @as(u64, options.duration_s) * 1000;

    var poll = Poll.init(timer_fd, pid_fd, options.cancel);

    while (true) {
        // Wake up for the deadline too, even if no descriptor is ready.
        const timeout: c_int = if (deadline) |d| blk: {
            const now = timer.nowMs();
            break :blk if (now >= d) 0 else @intCast(@min(d - now, std.math.maxInt(c_int)));
        } else -1;

        const event = poll.wait(timeout) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
        var reported = false;
        if (event.timer) {
            var expirations: u64 = undefined;
            _ = try sys.readFd(timer_fd, &expirations, @sizeOf(u64));
            try deliver(allocator, &session, context, onReport);
            reported = true;
        }

        const finished = if (deadline) |d| timer.nowMs() >= d else false;
        if (event.exited or event.cancelled or finished) {
            if (!reported) try deliver(allocator, &session, context, onReport); // the last, partial window
            const reason: StopReason = if (event.cancelled) .cancelled else if (event.exited) .target_exited else .duration;
            return reason;
        }
    }
}
/// Takes one report and hands it to the caller. The report lives in an arena that is freed
/// right after the callback returns.
fn deliver(allocator: std.mem.Allocator, session: *Session, context: anytype, comptime onReport: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const report = try session.report(arena.allocator());

    // The callback may return void or an error union; an error stops the run.
    const Return = @typeInfo(@TypeOf(onReport)).@"fn".return_type.?;
    if (@typeInfo(Return) == .error_union) try onReport(context, &report) else onReport(context, &report);
}

/// Clear compile errors for the easy mistakes, instead of a long error from inside.
fn checkCallback(comptime Context: type, comptime onReport: anytype) void {
    const pointer = switch (@typeInfo(Context)) {
        .pointer => |p| p,
        else => @compileError("profile: `context` must be a pointer to your state, for example &state"),
    };

    if (pointer.size != .one or pointer.is_const) {
        @compileError("profile: `context` must be a mutable pointer to a single value, for example &state");
    }

    const callback = switch (@typeInfo(@TypeOf(onReport))) {
        .@"fn" => |f| f,
        else => @compileError("profile: `onReport` must be a function"),
    };
    if (callback.params.len != 2 or callback.params[0].type.? != Context or callback.params[1].type.? != *const Report) {
        @compileError("profile: `onReport` must be `fn (" ++ @typeName(Context) ++ ", *const Report) !void`");
    }
}

// testing

const Set = std.EnumSet(cfg.Metric);

const Counter = struct {
    reports: usize = 0,
    samples: u64 = 0,

    fn onReport(self: *Counter, report: *const Report) void {
        self.reports += 1;
        if (report.cpu) |cpu| self.samples += cpu.samples;
    }
};

test "stops when the target exits and reports its CPU use (needs root, skipped otherwise)" {
    const child = try sys.spawnBurner(700);
    defer sys.reap(child);

    var counter = Counter{};
    const started = timer.nowMs();
    const reason = profile(std.testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 200,
        .duration_s = 0,
    }, &counter, Counter.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const elapsed = timer.nowMs() - started;

    std.debug.print("driver: {d} reports, {d} samples, {d} ms\n", .{ counter.reports, counter.samples, elapsed });
    try std.testing.expectEqual(StopReason.target_exited, reason);
    try std.testing.expect(elapsed < 1500);
    try std.testing.expect(counter.reports >= 3); // ticks at 200, 400, 600 ms, then the exit
    try std.testing.expect(counter.samples >= 20); // about 69 for 700 ms at 99 Hz
}

test "stops at the duration while the target keeps running (needs root, skipped otherwise)" {
    const child = try sys.spawnBurner(5000);
    defer sys.reap(child);

    var counter = Counter{};
    const started = timer.nowMs();
    const reason = profile(std.testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 1,
    }, &counter, Counter.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const elapsed = timer.nowMs() - started;

    std.debug.print("driver: {d} reports, {d} samples, {d} ms\n", .{ counter.reports, counter.samples, elapsed });
    try std.testing.expectEqual(StopReason.duration, reason);
    try std.testing.expect(elapsed >= 1000 and elapsed < 1500);
    try std.testing.expect(counter.reports >= 3 and counter.reports <= 5);
    try std.testing.expect(counter.samples >= 40);
}

test "a handle triggered before the run stops it at once (needs root, skipped otherwise)" {
    const child = try sys.spawnBurner(5000);
    defer sys.reap(child);

    var cancel = try Cancel.init();
    defer cancel.deinit();
    cancel.trigger();

    var counter = Counter{};
    const started = timer.nowMs();
    const reason = profile(std.testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 1000,
        .duration_s = 0,
        .cancel = &cancel,
    }, &counter, Counter.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(StopReason.cancelled, reason);
    try std.testing.expectEqual(@as(usize, 1), counter.reports); // just the final window
    try std.testing.expect(timer.nowMs() - started < 500);
}
