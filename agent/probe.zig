//! A function probe run: finds a function in a process, times every call of it, and reports
//! the totals once per interval.

const std = @import("std");
const protocol = @import("shared").protocol;
const os = @import("os/os.zig");
const target_layer = @import("target/target.zig");
const metrics_layer = @import("metrics/metrics.zig");
const log = @import("log.zig").agent;

const timer = os.timer;
const PidFd = os.pidfd.PidFd;
const Cancel = os.cancel.Cancel;
const Probe = metrics_layer.probe.Probe;
const function = metrics_layer.probe.function;

pub const Options = struct {
    pid: u32,
    function: []const u8,
    /// The file to look in, by path or file name; null looks in all of them.
    module: ?[]const u8 = null,
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,
};

/// Each is valid until the next `next`.
pub const Event = protocol.ProbeEvent;

const Source = enum { report_timer, target_exit, cancel };
const Poll = os.poll.Poll(Source);

pub const ProbeRun = struct {
    gpa: std.mem.Allocator,
    probe: *Probe,
    info: protocol.probe.Info,
    pidfd: PidFd,
    cancel: Cancel,
    report_timer: timer.Timer,
    poll: Poll,
    deadline_ns: ?u64,
    report: protocol.probe.Report,
    window_start_monotonic_ns: u64,
    window_start_unix_ns: u64,
    phase: enum { attached, running, closing, ended },
    stop_reason: protocol.RunStop,

    /// Needs root, or CAP_BPF and CAP_PERFMON.
    pub fn init(gpa: std.mem.Allocator, options: Options) !ProbeRun {
        errdefer |err| log.err("probing failed", .{ .pid = options.pid, .cause = err });
        if (options.interval_ms == 0) return error.InvalidInterval;
        if (!os.process.pid_valid(options.pid)) return error.InvalidPid;
        if (options.function.len == 0) return error.FunctionNotFound;

        const info = try info_find(gpa, options);
        errdefer info_free(gpa, info);
        const probe = try gpa.create(Probe);
        errdefer gpa.destroy(probe);
        try probe.init(gpa, .{ .pid = options.pid, .path = info.path, .offset = info.offset });
        errdefer probe.deinit(gpa);
        var pidfd = try PidFd.init(options.pid);
        errdefer pidfd.deinit();
        var cancel = try Cancel.init();
        errdefer cancel.deinit();
        var report_timer = try timer.Timer.init(options.interval_ms);
        errdefer report_timer.deinit();

        return .{
            .gpa = gpa,
            .probe = probe,
            .info = info,
            .pidfd = pidfd,
            .cancel = cancel,
            .report_timer = report_timer,
            .poll = Poll.init(.init(.{
                .report_timer = report_timer.fd,
                .target_exit = pidfd.fd,
                .cancel = cancel.fd,
            })),
            .deadline_ns = timer.deadline_from(options.duration_s),
            .report = undefined,
            .window_start_monotonic_ns = timer.monotonic_ns(),
            .window_start_unix_ns = timer.realtime_ns(),
            .phase = .attached,
            .stop_reason = .cancelled,
        };
    }

    pub fn deinit(run: *ProbeRun) void {
        run.report_timer.deinit();
        run.cancel.deinit();
        run.pidfd.deinit();
        run.probe.deinit(run.gpa);
        run.gpa.destroy(run.probe);
        info_free(run.gpa, run.info);
        run.* = undefined;
    }

    pub fn next(run: *ProbeRun) !?Event {
        switch (run.phase) {
            .ended => return null,
            .attached => {
                run.phase = .running;
                return .{ .attached = &run.info };
            },
            .closing => {
                run.phase = .ended;
                log.info("probing stopped", .{ .pid = run.info.pid, .reason = run.stop_reason });
                return .{ .stopped = run.stop_reason };
            },
            .running => {},
        }
        while (true) {
            const ready = try run.poll.wait(timer.timeout_ms(run.deadline_ns));
            const reason: ?protocol.RunStop = if (ready.contains(.cancel))
                .cancelled
            else if (ready.contains(.target_exit))
                .target_exited
            else if (run.deadline_ns != null and timer.monotonic_ns() >= run.deadline_ns.?)
                .duration
            else
                null;
            if (reason) |ending| {
                run.stop_reason = ending;
                run.phase = .closing;
                return try run.report_take();
            }
            if (ready.contains(.report_timer)) {
                _ = try run.report_timer.expirations_read();
                return try run.report_take();
            }
        }
    }

    /// Safe from any thread, and from a signal handler.
    pub fn stop(run: *const ProbeRun) void {
        run.cancel.trigger();
    }

    fn report_take(run: *ProbeRun) !Event {
        const now_monotonic_ns = timer.monotonic_ns();
        run.report = .{
            .start_unix_ns = run.window_start_unix_ns,
            .duration_ns = now_monotonic_ns - run.window_start_monotonic_ns,
            .totals = try run.probe.read(),
        };
        run.window_start_monotonic_ns = now_monotonic_ns;
        run.window_start_unix_ns = timer.realtime_ns();
        return .{ .report = &run.report };
    }
};

fn info_find(gpa: std.mem.Allocator, options: Options) !protocol.probe.Info {
    var target = try target_layer.Target.init(gpa, options.pid);
    defer target.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const found = try function.find(
        arena.allocator(),
        options.pid,
        target.regions,
        options.module,
        options.function,
    );
    const name = try gpa.dupe(u8, options.function);
    errdefer gpa.free(name);
    return .{
        .pid = options.pid,
        .function = name,
        .path = try gpa.dupe(u8, found.path),
        .offset = found.offset,
        .size = found.size,
    };
}

fn info_free(gpa: std.mem.Allocator, info: protocol.probe.Info) void {
    gpa.free(info.function);
    gpa.free(info.path);
}

const testing = std.testing;
const child_process = @import("testing/process.zig");

test "a bad option is refused before anything is attached" {
    const gpa = testing.allocator;
    const no_interval = ProbeRun.init(gpa, .{ .pid = 1, .function = "f", .interval_ms = 0 });
    try testing.expectError(error.InvalidInterval, no_interval);
    try testing.expectError(error.InvalidPid, ProbeRun.init(gpa, .{ .pid = 0, .function = "f" }));
    const nameless = ProbeRun.init(testing.allocator, .{ .pid = 1, .function = "" });
    try testing.expectError(error.FunctionNotFound, nameless);
}

test "a probe run attaches, reports every interval, and ends with the process (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const caller = try child_process.caller_spawn(300, 20_000, 1);
    var run = ProbeRun.init(testing.allocator, .{
        .pid = caller.pid,
        .function = "testing.process.probed_function",
        .interval_ms = 100,
    }) catch |err| {
        child_process.child_reap(caller.pid);
        return err;
    };
    defer run.deinit();
    child_process.caller_start(caller);

    var attached = false;
    var reports: u32 = 0;
    var last = protocol.probe.Totals{};
    var stopped: ?protocol.RunStop = null;
    while (try run.next()) |event| switch (event) {
        .attached => |info| {
            attached = true;
            try testing.expectEqual(caller.pid, info.pid);
            try testing.expect(info.size > 0);
        },
        .report => |report| {
            reports += 1;
            try testing.expect(report.totals.calls >= last.calls);
            last = report.totals;
        },
        .stopped => |reason| stopped = reason,
    };
    child_process.child_wait(caller.pid);
    try testing.expect(attached);
    try testing.expectEqual(@as(?protocol.RunStop, .target_exited), stopped);
    try testing.expectEqual(@as(u64, 300), last.calls);
    try testing.expectEqual(@as(u64, 300), last.timed);
    std.debug.print("probe run: {d} reports, {d} calls\n", .{ reports, last.calls });
}

test "a function that does not exist is refused, and so is a Go program" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const own = os.process.current_pid();
    const unknown = Options{ .pid = own, .function = "no_such_function_nusku" };
    const missing = ProbeRun.init(testing.allocator, unknown);
    try testing.expectError(error.FunctionNotFound, missing);

    var cwd: [4096]u8 = undefined;
    const got = std.os.linux.getcwd(&cwd, cwd.len);
    if (std.os.linux.errno(got) != .SUCCESS) return error.SkipZigTest;
    const here = std.mem.sliceTo(&cwd, 0);
    const path = "{s}/testing/out/go-app";
    const go_app = try std.fmt.allocPrintSentinel(testing.allocator, path, .{here}, 0);
    defer testing.allocator.free(go_app);
    if (std.os.linux.errno(std.os.linux.access(go_app, std.os.linux.X_OK)) != .SUCCESS) {
        return error.SkipZigTest;
    }
    const pid = std.c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ go_app.ptr, "5" };
        _ = std.os.linux.execve(go_app.ptr, &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    defer child_process.child_reap(@intCast(pid));
    os.timer.sleep_ms(300);
    const go_options = Options{ .pid = @intCast(pid), .function = "main.hotLeaf" };
    const go = ProbeRun.init(testing.allocator, go_options);
    try testing.expectError(error.GoProgram, go);
}
