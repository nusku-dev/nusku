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
const Offer = @import("symbols/offer.zig").Offer;
const binary_file = @import("symbols/binary.zig");
const poll_file = @import("os/poll.zig");
const session_file = @import("session.zig");
const log = @import("log.zig").agent;

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
///
/// The state may also take the target's binaries, so the server can name addresses. It then
/// has all five of these, on the same thread as `on_report`:
///
///     fn binary_known(state: *State, build_id: []const u8) bool   // true: do not send it
///     fn binary_begin(state: *State, header: *const binary_file.Header) !void
///     fn binary_chunk(state: *State, chunk: *const binary_file.Chunk) !void
///     fn binary_end(state: *State) !void
///     fn binary_abort(state: *State) void   // the binary begun will not end: drop it
///
/// Each binary is offered once per run. Its stream is begin, chunks, then end or abort. An
/// error from a hook drops that binary only; the run goes on.
pub fn profile(
    gpa: std.mem.Allocator,
    options: Options,
    context: anytype,
    comptime on_report: anytype,
) !StopReason {
    comptime callback_check(@TypeOf(context), on_report);
    comptime hooks_check(@TypeOf(context));
    // One line saying why a run failed, for a host that only reads the log.
    errdefer |err| log.err("profiling failed", .{ .pid = options.pid, .cause = err });
    try options_check(options);

    var pidfd = try PidFd.init(options.pid);
    defer pidfd.deinit();

    // On the heap: it is large, and the collectors keep pointers into it.
    const session = try gpa.create(Session);
    defer gpa.destroy(session);

    try session.init(gpa, .{ .pid = options.pid, .metrics = options.metrics });
    defer session.deinit(gpa);

    var offer: Offer = undefined;
    const wanted = comptime binaries_wanted(@TypeOf(context));
    try offer.init(gpa, wanted, options.pid, session.vdso_image());
    defer offer.deinit(gpa);
    // Also when the run fails: a binary in flight is aborted, not left half sent.
    defer if (wanted) offer.stop(context);

    // Armed only now: loading the program and building the tables can take longer than an
    // interval, and the first window must be a whole one, counted from when sampling began.
    var report_timer = try Timer.init(options.interval_ms);
    defer report_timer.deinit();

    var tick_timer = try Timer.init(@min(tick_ms_max, options.interval_ms));
    defer tick_timer.deinit();

    var poll = Poll.init(.init(.{
        .report_timer = report_timer.fd,
        .tick_timer = tick_timer.fd,
        .target_exit = pidfd.fd,
        .cancel = if (options.cancel) |cancel| cancel.fd else -1,
    }));
    log.info("profiling started", .{
        .pid = options.pid,
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
    });

    const started_ns = timer.monotonic_ns();
    const run = try loop_run(gpa, session, .{
        .poll = &poll,
        .report_timer = &report_timer,
        .tick_timer = &tick_timer,
        .deadline_ns = deadline_from(options.duration_s),
        .offer = &offer,
    }, context, on_report);

    log.info("profiling stopped", .{
        .pid = options.pid,
        .reason = run.stop,
        .reports = run.reports,
        .seconds = (timer.monotonic_ns() - started_ns) / std.time.ns_per_s,
    });
    return run.stop;
}

/// Refuses options that cannot run, before anything is loaded.
fn options_check(options: Options) !void {
    if (options.interval_ms == 0) return error.InvalidInterval;
    if (options.metrics.count() == 0) return error.NoMetrics;
    if (!process.pid_valid(options.pid)) return error.InvalidPid;
}

/// When a run of `duration_s` seconds that starts now ends; null for a run without an end.
fn deadline_from(duration_s: u32) ?u64 {
    if (duration_s == 0) return null;
    return timer.monotonic_ns() + @as(u64, duration_s) * std.time.ns_per_s;
}

/// What the loop waits on.
const LoopSources = struct {
    poll: *Poll,
    report_timer: *const Timer,
    tick_timer: *const Timer,
    deadline_ns: ?u64,
    offer: *Offer,
};

const LoopResult = struct { stop: StopReason, reports: u64 };

/// The event loop: it ends only by a stop condition, and every round waits on poll, so it
/// cannot spin.
fn loop_run(
    gpa: std.mem.Allocator,
    session: *Session,
    sources: LoopSources,
    context: anytype,
    comptime on_report: anytype,
) !LoopResult {
    var reports: u64 = 0;
    while (true) {
        const ready = try sources.poll.wait(timeout_ms(sources.deadline_ns));

        if (ready.contains(.tick_timer)) {
            _ = try sources.tick_timer.expirations_read();
            try session.tick();
            if (comptime binaries_wanted(@TypeOf(context))) sources.offer.pump(context);
        }
        var reported = false;
        if (ready.contains(.report_timer)) {
            // Missed periods are not made up: one late report covers them, its duration says so.
            _ = try sources.report_timer.expirations_read();
            try report_deliver(gpa, session, sources.offer, context, on_report);
            reports += 1;
            reported = true;
        }

        const stop = stop_reason(ready, sources.deadline_ns) orelse continue;
        // The last, partial window.
        if (!reported) {
            try report_deliver(gpa, session, sources.offer, context, on_report);
            reports += 1;
        }
        return .{ .stop = stop, .reports = reports };
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
    offer: *Offer,
    context: anytype,
    comptime on_report: anytype,
) !void {
    const report = try session.report(gpa);
    if (comptime binaries_wanted(@TypeOf(context))) offer.regions_see(report.regions);
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

/// A context with one binary hook needs all five, each with its signature (see `profile`): a
/// half conversation is a bug, and the error should say which hook is wrong.
fn hooks_check(comptime Context: type) void {
    if (!binaries_wanted(Context)) return;
    const State = @typeInfo(Context).pointer.child;
    const hooks = .{
        .{ "binary_known", []const u8, false },
        .{ "binary_begin", *const binary_file.Header, true },
        .{ "binary_chunk", *const binary_file.Chunk, true },
        .{ "binary_end", void, true },
        .{ "binary_abort", void, false },
    };
    inline for (hooks) |hook| {
        const name, const Argument, const fails = hook;
        const prefix = "profile: `" ++ @typeName(State) ++ "." ++ name ++ "`";
        if (!@hasDecl(State, name)) @compileError(prefix ++ " is missing");

        const function = @typeInfo(@TypeOf(@field(State, name))).@"fn";
        const arguments = if (Argument == void) 1 else 2;
        if (function.params.len != arguments) @compileError(prefix ++ ": wrong parameters");
        if (function.params[0].type.? != Context) @compileError(prefix ++ ": wrong state");
        if (Argument != void and function.params[1].type.? != Argument) {
            @compileError(prefix ++ ": wrong argument type");
        }
        const Return = function.return_type.?;
        const returns_error = @typeInfo(Return) == .error_union;
        if (fails and !(returns_error or Return == void)) {
            @compileError(prefix ++ ": must return !void");
        }
        if (!fails and returns_error) @compileError(prefix ++ ": must not fail");
    }
}

/// Whether the context takes part in the binary conversation: it has `binary_known`.
fn binaries_wanted(comptime Context: type) bool {
    return @hasDecl(@typeInfo(Context).pointer.child, "binary_known");
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

/// Like `Counter`, and it also takes part in the binary conversation: it counts what the agent
/// asks and sends. It always answers "not known", so the agent should send everything.
const HookedCounter = struct {
    reports: u32 = 0,
    known_asked: u32 = 0,
    begins: u32 = 0,
    chunks: u32 = 0,
    ends: u32 = 0,
    aborts: u32 = 0,

    fn on_report(counter: *HookedCounter, report: *const Report) void {
        _ = report;
        counter.reports += 1;
    }

    pub fn binary_known(counter: *HookedCounter, build_id: []const u8) bool {
        _ = build_id;
        counter.known_asked += 1;
        return false;
    }

    pub fn binary_begin(counter: *HookedCounter, header: *const binary_file.Header) !void {
        const format = "hooks: begin {s}, symtab {d}, strtab {d}, dynsym {d}, dynstr {d}, " ++
            "segments {d}\n";
        std.debug.print(format, .{
            header.path,
            header.sizes.get(.symtab),
            header.sizes.get(.strtab),
            header.sizes.get(.dynsym),
            header.sizes.get(.dynstr),
            header.segments.len,
        });
        counter.begins += 1;
    }

    pub fn binary_chunk(counter: *HookedCounter, chunk: *const binary_file.Chunk) !void {
        _ = chunk;
        counter.chunks += 1;
    }

    pub fn binary_end(counter: *HookedCounter) !void {
        counter.ends += 1;
    }

    pub fn binary_abort(counter: *HookedCounter) void {
        counter.aborts += 1;
    }
};

test "a context with binary hooks gets its reports and the binaries (needs root, else skipped)" {
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    var counter = HookedCounter{};
    const reason = profile(testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 1,
    }, &counter, HookedCounter.on_report) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try testing.expectEqual(StopReason.duration, reason);
    try testing.expect(counter.reports >= 3);

    // The agent asked about the binaries it found, and every transfer it began either ended or
    // was aborted when the run stopped.
    std.debug.print("hooks: asked {d}, begun {d}, chunks {d}, ended {d}, aborted {d}\n", .{
        counter.known_asked, counter.begins, counter.chunks, counter.ends, counter.aborts,
    });
    try testing.expect(counter.known_asked >= 1);
    try testing.expect(counter.begins >= 1);
    try testing.expectEqual(counter.begins, counter.ends + counter.aborts);
    try testing.expect(counter.aborts <= 1);
    try testing.expect(counter.known_asked >= counter.begins);
    try testing.expect(counter.chunks >= counter.begins);
}

test "the timeout reaches the deadline, and none means wait for ever" {
    try testing.expectEqual(@as(i32, -1), timeout_ms(null));
    try testing.expectEqual(@as(i32, 0), timeout_ms(0));
    const timeout = timeout_ms(timer.monotonic_ns() + 50 * std.time.ns_per_ms);
    try testing.expect(timeout > 0);
    try testing.expect(timeout <= 50);
}

test "stops when the target exits and reports its CPU use (needs root, skipped otherwise)" {
    // Long enough that the child is still alive when the start-up (tables) is done.
    const child = try child_process.burner_spawn(2500);
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
    try testing.expect(elapsed_ms < 5000);
    // Reports every 200 ms from when sampling began, then one at the exit.
    try testing.expect(counter.reports >= 2);
    try testing.expect(counter.samples >= 20);
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

    std.debug.print("duration: {d} reports, {d} samples, {d} ms\n", .{
        counter.reports, counter.samples, elapsed_ms,
    });
    try testing.expectEqual(StopReason.duration, reason);
    try testing.expect(elapsed_ms >= 1000);
    try testing.expect(elapsed_ms < 2500);
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
    const elapsed_ms = (timer.monotonic_ns() - started_ns) / std.time.ns_per_ms;

    std.debug.print("cancel: stopped after {d} ms\n", .{elapsed_ms});
    try testing.expectEqual(StopReason.cancelled, reason);
    try testing.expectEqual(@as(u32, 1), counter.reports); // Just the last window.
    try testing.expect(elapsed_ms < 2000);
}
