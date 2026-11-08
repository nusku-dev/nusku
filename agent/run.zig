//! A profiling run, pulled one event at a time: reports at every interval, and the target's
//! binaries when the caller wants them. The parent of the layers: it takes what the target,
//! ebpf and symbols give, and makes the protocol's events of it.
//!
//!     var run = try Run.init(gpa, .{ .pid = pid });
//!     defer run.deinit();
//!     while (try run.next()) |event| switch (event) { ... };
//!
//! The loop runs inside `next`: a tick drains the kernel's buffers, then sends a little of a
//! binary; the report timer gives the reports. Needs root, or CAP_BPF and CAP_PERFMON (and
//! CAP_SYSLOG for kernel addresses).

const std = @import("std");
const protocol = @import("shared").protocol;
const os = @import("os.zig");
const target_layer = @import("target.zig");
const ebpf_layer = @import("ebpf.zig");
const symbols_layer = @import("symbols.zig");
const message_file = @import("message.zig");
const log = @import("log.zig").agent;

const timer = os.timer;
const Timer = timer.Timer;
const PidFd = os.pidfd.PidFd;
const Cancel = os.cancel.Cancel;
const Target = target_layer.Target;
const Ebpf = ebpf_layer.Ebpf;
const Symbols = symbols_layer.Symbols;

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(protocol.Metric) = .initOne(.cpu),
    /// Milliseconds between reports.
    interval_ms: u32 = 1000,
    /// 0: until the target exits or `stop`.
    duration_s: u32 = 0,
    /// Offers the target's binaries, so their addresses can be named.
    binaries: bool = true,
};

/// Each is valid until the next `next`.
pub const Event = protocol.RunEvent;

/// The ring cannot fill between two ticks: at 99 Hz on 64 CPUs a tick sees 634 samples.
const tick_ms_max = 100;
/// Binary events per tick: with chunks of 256 KiB, at most 1.5 MiB per 100 ms.
const binary_steps_per_tick = 6;

const Source = enum { report_timer, tick_timer, target_exit, cancel };
const Poll = os.poll.Poll(Source);

/// The layers of one run, together on the heap: ebpf and symbols point into the target, and
/// the collectors into ebpf.
const Layers = struct {
    target: Target,
    ebpf: Ebpf,
    symbols: Symbols,

    fn create(gpa: std.mem.Allocator, options: Options) !*Layers {
        const layers = try gpa.create(Layers);
        errdefer gpa.destroy(layers);
        layers.target = try Target.init(gpa, options.pid);
        errdefer layers.target.deinit(gpa);
        const target = &layers.target;
        try layers.ebpf.init(gpa, target, .{ .metrics = options.metrics });
        errdefer layers.ebpf.deinit(gpa);
        const binaries = options.binaries;
        try layers.symbols.init(gpa, binaries, target.pid, target.vdso_image(), target.kernel);
        return layers;
    }

    fn destroy(layers: *Layers, gpa: std.mem.Allocator) void {
        layers.symbols.deinit(gpa);
        layers.ebpf.deinit(gpa);
        layers.target.deinit(gpa);
        gpa.destroy(layers);
    }
};

pub const Run = struct {
    gpa: std.mem.Allocator,
    pid: u32,
    layers: *Layers,
    pidfd: PidFd,
    cancel: Cancel,
    report_timer: Timer,
    tick_timer: Timer,
    poll: Poll,
    deadline_ns: ?u64,
    /// The last report, in `message_arena`.
    message: protocol.Message,
    message_arena: std.heap.ArenaAllocator,
    phase: enum { running, closing, ended },
    stop_reason: protocol.RunStop,
    /// Binary events left in this tick.
    binary_steps: u32,
    reports: u64,
    started_ns: u64,

    /// Loads the sampler and builds the target's tables: this can take a second.
    pub fn init(gpa: std.mem.Allocator, options: Options) !Run {
        errdefer |err| log.err("profiling failed", .{ .pid = options.pid, .cause = err });
        if (options.interval_ms == 0) return error.InvalidInterval;
        if (options.metrics.count() == 0) return error.NoMetrics;
        if (!os.process.pid_valid(options.pid)) return error.InvalidPid;

        const layers = try Layers.create(gpa, options);
        errdefer layers.destroy(gpa);
        var pidfd = try PidFd.init(options.pid);
        errdefer pidfd.deinit();
        var cancel = try Cancel.init();
        errdefer cancel.deinit();
        // Armed only now, after the setup: the first window is a whole one.
        var report_timer = try Timer.init(options.interval_ms);
        errdefer report_timer.deinit();
        var tick_timer = try Timer.init(@min(tick_ms_max, options.interval_ms));
        errdefer tick_timer.deinit();

        log.info("profiling started", .{
            .pid = options.pid,
            .interval_ms = options.interval_ms,
            .duration_s = options.duration_s,
        });
        return .{
            .gpa = gpa,
            .pid = options.pid,
            .layers = layers,
            .pidfd = pidfd,
            .cancel = cancel,
            .report_timer = report_timer,
            .tick_timer = tick_timer,
            .poll = Poll.init(.init(.{
                .report_timer = report_timer.fd,
                .tick_timer = tick_timer.fd,
                .target_exit = pidfd.fd,
                .cancel = cancel.fd,
            })),
            .deadline_ns = timer.deadline_from(options.duration_s),
            .message = undefined,
            .message_arena = .init(gpa),
            .phase = .running,
            .stop_reason = .cancelled,
            .binary_steps = 0,
            .reports = 0,
            .started_ns = timer.monotonic_ns(),
        };
    }

    pub fn deinit(run: *Run) void {
        run.tick_timer.deinit();
        run.report_timer.deinit();
        run.layers.destroy(run.gpa);
        run.cancel.deinit();
        run.pidfd.deinit();
        run.message_arena.deinit();
        run.* = undefined;
    }

    /// The next event, waiting for it. Null after `.stopped`.
    pub fn next(run: *Run) !?Event {
        while (true) {
            switch (run.phase) {
                .ended => return null,
                .closing => return run.close(),
                .running => {},
            }
            if (run.binary_steps > 0) {
                run.binary_steps -= 1;
                if (run.layers.symbols.step()) |event| return event_of(event);
                run.binary_steps = 0;
            }
            if (try run.wait()) |event| return event;
        }
    }

    /// Answers `.binary_offer`. During a transfer, false drops the binary.
    pub fn binary_want(run: *Run, wanted: bool) void {
        run.layers.symbols.want(wanted);
    }

    /// Ends the run at its next wait. Safe from any thread, and from a signal handler.
    pub fn stop(run: *const Run) void {
        run.cancel.trigger();
    }

    /// One wait: a tick starts a round of binary events, the report timer or the end a report.
    fn wait(run: *Run) !?Event {
        const ready = try run.poll.wait(timer.timeout_ms(run.deadline_ns));
        if (ready.contains(.tick_timer)) {
            _ = try run.tick_timer.expirations_read();
            try run.layers.ebpf.tick();
            run.binary_steps = binary_steps_per_tick;
        }
        // Missed periods are not made up: one late report covers them.
        const due = ready.contains(.report_timer);
        if (due) _ = try run.report_timer.expirations_read();
        const stop_reason = stop_reason_of(ready, run.deadline_ns);
        if (!due and stop_reason == null) return null;
        if (stop_reason) |reason| {
            run.stop_reason = reason;
            run.phase = .closing;
        }
        return try run.report();
    }

    fn report(run: *Run) !Event {
        const layers = run.layers;
        const windows = try layers.ebpf.collect(run.gpa, &layers.target);
        layers.symbols.regions_see(layers.target.regions);
        _ = run.message_arena.reset(.retain_capacity);
        run.message = try message_file.build(run.message_arena.allocator(), .{
            .pid = run.pid,
            .regions = layers.target.regions,
            .kernel = layers.target.kernel,
            .windows = &windows,
        });
        run.reports += 1;
        return .{ .report = &run.message };
    }

    /// After the last report: the abort of a binary in flight, then `.stopped`.
    fn close(run: *Run) Event {
        if (run.layers.symbols.stop()) return .binary_abort;
        run.phase = .ended;
        log.info("profiling stopped", .{
            .pid = run.pid,
            .reason = run.stop_reason,
            .reports = run.reports,
            .seconds = (timer.monotonic_ns() - run.started_ns) / std.time.ns_per_s,
        });
        return .{ .stopped = run.stop_reason };
    }
};

fn event_of(event: symbols_layer.Event) Event {
    return switch (event) {
        .offer => |offered| .{ .binary_offer = offered },
        .begin => |header| .{ .binary_begin = header },
        .chunk => |chunk| .{ .binary_chunk = chunk },
        .end => .binary_end,
        .abort => .binary_abort,
    };
}

/// A cancel wins over the target's exit, which wins over the duration.
fn stop_reason_of(ready: std.EnumSet(Source), deadline_ns: ?u64) ?protocol.RunStop {
    if (ready.contains(.cancel)) return .cancelled;
    if (ready.contains(.target_exit)) return .target_exited;
    const deadline = deadline_ns orelse return null;
    return if (timer.monotonic_ns() >= deadline) .duration else null;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("testing/process.zig");

/// What a run gave, and the binaries it was sent whole.
const Seen = struct {
    reports: u32 = 0,
    samples: u64 = 0,
    offers: u32 = 0,
    begins: u32 = 0,
    chunks: u32 = 0,
    ends: u32 = 0,
    aborts: u32 = 0,
    stopped: ?protocol.RunStop = null,
    elapsed_ms: u64 = 0,

    /// Runs `options` to its end, as root; null without the rights.
    fn of(options: Options) !?Seen {
        const started_ns = timer.monotonic_ns();
        var run = Run.init(testing.allocator, options) catch |err| switch (err) {
            error.PermissionDenied => return null,
            else => return err,
        };
        defer run.deinit();
        var seen = Seen{};
        while (try run.next()) |event| switch (event) {
            .report => |message| {
                seen.reports += 1;
                seen.samples += message.samples;
            },
            .binary_offer => {
                seen.offers += 1;
                run.binary_want(true);
            },
            .binary_begin => seen.begins += 1,
            .binary_chunk => seen.chunks += 1,
            .binary_end => seen.ends += 1,
            .binary_abort => seen.aborts += 1,
            .stopped => |reason| seen.stopped = reason,
        };
        seen.elapsed_ms = (timer.monotonic_ns() - started_ns) / std.time.ns_per_ms;
        return seen;
    }
};

test "a bad option is refused before anything is loaded" {
    try testing.expectError(error.InvalidPid, Run.init(testing.allocator, .{ .pid = 0 }));
    const no_interval = Run.init(testing.allocator, .{ .pid = 1, .interval_ms = 0 });
    try testing.expectError(error.InvalidInterval, no_interval);
    const no_metrics = Run.init(testing.allocator, .{ .pid = 1, .metrics = .initEmpty() });
    try testing.expectError(error.NoMetrics, no_metrics);
}

test "a run stops at its duration, with its reports and the binaries (root)" {
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);
    const seen = (try Seen.of(.{ .pid = child, .interval_ms = 300, .duration_s = 1 })) orelse
        return error.SkipZigTest;

    std.debug.print("run: {d} reports, {d} samples, {d} ms; binaries: {d} offered, " ++
        "{d} begun, {d} chunks, {d} ended, {d} aborted\n", .{
        seen.reports, seen.samples, seen.elapsed_ms, seen.offers,
        seen.begins,  seen.chunks,  seen.ends,       seen.aborts,
    });
    try testing.expectEqual(@as(?protocol.RunStop, .duration), seen.stopped);
    try testing.expect(seen.elapsed_ms >= 1000 and seen.elapsed_ms < 2500);
    try testing.expect(seen.reports >= 3 and seen.reports <= 5);
    try testing.expect(seen.samples >= 40);
    // Every binary begun ended, or was aborted when the run stopped.
    try testing.expect(seen.begins >= 1);
    try testing.expectEqual(seen.begins, seen.ends + seen.aborts);
    try testing.expect(seen.aborts <= 1);
}

test "a run stops when the target exits (root)" {
    const child = try child_process.burner_spawn(2500);
    defer child_process.child_reap(child);
    const options = Options{ .pid = child, .interval_ms = 200, .binaries = false };
    const seen = (try Seen.of(options)) orelse return error.SkipZigTest;

    try testing.expectEqual(@as(?protocol.RunStop, .target_exited), seen.stopped);
    try testing.expect(seen.elapsed_ms < 5000);
    try testing.expect(seen.reports >= 2);
    try testing.expect(seen.samples >= 20);
    try testing.expectEqual(@as(u32, 0), seen.offers);
}

test "stop ends the run at its next wait, with its last report (root)" {
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);
    var run = Run.init(testing.allocator, .{ .pid = child, .binaries = false }) catch |err|
        switch (err) {
            error.PermissionDenied => return error.SkipZigTest,
            else => return err,
        };
    defer run.deinit();

    run.stop();
    const started_ns = timer.monotonic_ns();
    var reports: u32 = 0;
    var stopped: ?protocol.RunStop = null;
    while (try run.next()) |event| switch (event) {
        .report => reports += 1,
        .stopped => |reason| stopped = reason,
        else => {},
    };
    const elapsed_ms = (timer.monotonic_ns() - started_ns) / std.time.ns_per_ms;
    std.debug.print("stop: ended after {d} ms\n", .{elapsed_ms});
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), stopped);
    try testing.expectEqual(@as(u32, 1), reports);
    try testing.expect(elapsed_ms < 1000);
}
