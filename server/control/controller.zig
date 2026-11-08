//! Starts and stops profiling runs and the processes watch, each on a thread of its own,
//! feeding the server in this process. Called from one control thread only.

const std = @import("std");
const assert = std.debug.assert;
const agent = @import("agent");
const Run = @import("run.zig").Run;
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;
const Upload = @import("../symbolize/upload.zig").Upload;
const WatchProcs = @import("watch_procs.zig").WatchProcs;
const log = @import("../log.zig").server;

pub const Spec = struct {
    pid: u32,
    metrics: std.EnumSet(agent.Metric),
    /// Milliseconds between reports.
    interval_ms: u32,
    /// 0: until the target exits or `stop`.
    duration_s: u32 = 0,
};

pub const WatchProcsSpec = struct {
    /// Milliseconds between two looks.
    interval_ms: u32,
    /// 0: until `watch_procs_stop`.
    duration_s: u32 = 0,
};

pub const Controller = struct {
    server: *Server,
    /// A run's thread points into its slot, so the array never moves.
    runs: []Run,
    /// One per machine, so one per controller.
    watch_procs: WatchProcs,
    upload_bytes_max: u64,

    pub const Options = struct {
        runs_max: u32 = 16,
        /// One binary's upload buffers, per run.
        upload_bytes_max: u64 = 512 * 1024 * 1024,
    };

    pub fn init(
        controller: *Controller,
        gpa: std.mem.Allocator,
        server: *Server,
        options: Options,
    ) !void {
        assert(options.runs_max > 0);
        assert(options.upload_bytes_max > 0);
        const runs = try gpa.alloc(Run, options.runs_max);
        for (runs) |*run| run.active = false;
        controller.* = .{
            .server = server,
            .runs = runs,
            .watch_procs = undefined,
            .upload_bytes_max = options.upload_bytes_max,
        };
        controller.watch_procs.active = false;
    }

    /// Stops whatever is still going, then frees the controller.
    pub fn deinit(controller: *Controller, gpa: std.mem.Allocator) void {
        for (controller.runs) |*run| {
            if (!run.active) continue;
            run.cancel.trigger();
            _ = controller.finish(gpa, run) catch {};
        }
        gpa.free(controller.runs);
        if (controller.watch_procs.active) {
            controller.watch_procs.cancel.trigger();
            _ = controller.watch_procs_finish() catch {};
        }
        controller.* = undefined;
    }

    // ---------------------------------------------------------------------- runs

    /// Registers the process with the server and starts profiling it. What only the agent
    /// can see (no permission, the process gone) comes out of `stop` or `join`.
    pub fn start(controller: *Controller, gpa: std.mem.Allocator, spec: Spec) !TargetId {
        errdefer |err| log.err("run not started", .{ .pid = spec.pid, .cause = err });
        if (spec.pid == 0) return error.InvalidPid;
        if (spec.interval_ms == 0) return error.InvalidInterval;
        if (spec.metrics.count() == 0) return error.NoMetrics;
        const run = controller.run_free() orelse return error.RunsFull;

        const window_bytes_max = controller.server.store.ring_options.window_bytes_max;
        const scratch = try gpa.alignedAlloc(u8, .@"8", window_bytes_max);
        errdefer gpa.free(scratch);
        var cancel = try agent.Cancel.init();
        errdefer cancel.deinit();
        const target = try controller.server.target_add(gpa, spec.pid);
        errdefer controller.server.target_remove(gpa, target) catch unreachable;

        run.* = .{
            .active = true,
            .server = controller.server,
            .target = target,
            .thread = undefined,
            .cancel = cancel,
            .options = .{
                .pid = spec.pid,
                .metrics = spec.metrics,
                .interval_ms = spec.interval_ms,
                .duration_s = spec.duration_s,
                .cancel = &run.cancel,
            },
            .scratch = scratch,
            .gpa = gpa,
            .upload = Upload.init(controller.upload_bytes_max),
            .ticket = null,
            .result = error.NotFinished,
            .finished = .init(false),
        };
        errdefer run.active = false;
        run.thread = try std.Thread.spawn(.{}, Run.thread_main, .{run});
        log.info("run started", .{
            .target = target,
            .pid = spec.pid,
            .interval_ms = spec.interval_ms,
            .duration_s = spec.duration_s,
        });
        return target;
    }

    /// Asks the run to stop, waits for it, and says why it stopped.
    pub fn stop(
        controller: *Controller,
        gpa: std.mem.Allocator,
        target: TargetId,
    ) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        run.cancel.trigger();
        return controller.finish(gpa, run);
    }

    /// Waits for the run to end by itself: its duration, or the target exiting.
    pub fn join(
        controller: *Controller,
        gpa: std.mem.Allocator,
        target: TargetId,
    ) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        return controller.finish(gpa, run);
    }

    /// False once `join` would return at once.
    pub fn running(controller: *Controller, target: TargetId) bool {
        const run = controller.run_find(target) orelse return false;
        return !run.finished.load(.acquire);
    }

    /// What stops the run from a signal handler. Good until `stop` or `join` returns.
    pub fn cancel_of(controller: *Controller, target: TargetId) ?*const agent.Cancel {
        const run = controller.run_find(target) orelse return null;
        return &run.cancel;
    }

    fn finish(controller: *Controller, gpa: std.mem.Allocator, run: *Run) !agent.StopReason {
        assert(run.active);
        run.thread.join();
        // Its windows stay for queries. Already gone only if removed by hand.
        controller.server.target_finish(run.target) catch {};
        const result = run.result;
        run.cancel.deinit();
        gpa.free(run.scratch);
        run.binary_abort(); // In case the agent did not end its transfer.
        run.upload.deinit(gpa);
        run.active = false;
        if (result) |reason| {
            log.info("run stopped", .{
                .target = run.target,
                .pid = run.options.pid,
                .reason = reason,
            });
        } else |err| {
            log.err("run failed", .{ .target = run.target, .pid = run.options.pid, .cause = err });
        }
        return result;
    }

    fn run_free(controller: *Controller) ?*Run {
        for (controller.runs) |*run| {
            if (!run.active) return run;
        }
        return null;
    }

    fn run_find(controller: *Controller, target: TargetId) ?*Run {
        for (controller.runs) |*run| {
            if (run.active and run.target == target) return run;
        }
        return null;
    }

    // ---------------------------------------------------------------------- processes watch

    pub fn watch_procs_start(
        controller: *Controller,
        gpa: std.mem.Allocator,
        spec: WatchProcsSpec,
    ) !void {
        errdefer |err| log.err("processes watch not started", .{ .cause = err });
        if (controller.watch_procs.active) return error.AlreadyWatchingProcs;
        if (spec.interval_ms == 0) return error.InvalidInterval;

        var cancel = try agent.Cancel.init();
        errdefer cancel.deinit();
        const watch_procs = &controller.watch_procs;
        watch_procs.* = .{
            .active = true,
            .server = controller.server,
            .thread = undefined,
            .cancel = cancel,
            .options = .{
                .interval_ms = spec.interval_ms,
                .duration_s = spec.duration_s,
                .cancel = &watch_procs.cancel,
            },
            .gpa = gpa,
            .result = error.NotFinished,
            .finished = .init(false),
        };
        errdefer watch_procs.active = false;
        watch_procs.thread = try std.Thread.spawn(.{}, WatchProcs.thread_main, .{watch_procs});
        log.info("processes watch started", .{
            .interval_ms = spec.interval_ms,
            .duration_s = spec.duration_s,
        });
    }

    /// Asks the watch to stop, waits for it, and says why it stopped.
    pub fn watch_procs_stop(controller: *Controller) !agent.processes.StopReason {
        if (!controller.watch_procs.active) return error.NotWatchingProcs;
        controller.watch_procs.cancel.trigger();
        return controller.watch_procs_finish();
    }

    pub fn watch_procs_running(controller: *Controller) bool {
        const watch_procs = &controller.watch_procs;
        return watch_procs.active and !watch_procs.finished.load(.acquire);
    }

    /// What stops the watch from a signal handler, like `cancel_of`.
    pub fn watch_procs_cancel_of(controller: *Controller) ?*const agent.Cancel {
        if (!controller.watch_procs.active) return null;
        return &controller.watch_procs.cancel;
    }

    fn watch_procs_finish(controller: *Controller) !agent.processes.StopReason {
        const watch_procs = &controller.watch_procs;
        assert(watch_procs.active);
        watch_procs.thread.join();
        const result = watch_procs.result;
        watch_procs.cancel.deinit();
        watch_procs.active = false;
        if (result) |reason| {
            log.info("processes watch stopped", .{ .reason = reason });
        } else |err| {
            log.err("processes watch failed", .{ .cause = err });
        }
        return result;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const burn = @import("../testing/burn.zig").burn;

/// A small server and its controller, on the heap: threads point into both.
const Fixture = struct {
    server: Server,
    controller: Controller,

    fn create(windows_per_target_max: u32, window_bytes_max: u32) !*Fixture {
        const fixture = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(fixture);
        try fixture.server.init(testing.allocator, .{
            .targets_max = 1,
            .windows_per_target_max = windows_per_target_max,
            .window_bytes_max = window_bytes_max,
        });
        errdefer fixture.server.deinit(testing.allocator);
        try fixture.controller.init(testing.allocator, &fixture.server, .{ .runs_max = 1 });
        return fixture;
    }

    fn destroy(fixture: *Fixture) void {
        fixture.controller.deinit(testing.allocator);
        fixture.server.deinit(testing.allocator);
        testing.allocator.destroy(fixture);
    }

    fn windows_count(fixture: *Fixture, target: TargetId) u32 {
        fixture.server.lock.lock();
        defer fixture.server.lock.unlock();
        return fixture.server.store.target_find(target).?.ring.count;
    }
};

const cpu_only = std.EnumSet(agent.Metric).initOne(.cpu);

test "a bad spec and an unknown run are refused before anything starts" {
    const fixture = try Fixture.create(2, 1024);
    defer fixture.destroy();
    const controller = &fixture.controller;
    const gpa = testing.allocator;

    const no_pid = Spec{ .pid = 0, .metrics = cpu_only, .interval_ms = 100 };
    try testing.expectError(error.InvalidPid, controller.start(gpa, no_pid));
    const no_interval = Spec{ .pid = 1, .metrics = cpu_only, .interval_ms = 0 };
    try testing.expectError(error.InvalidInterval, controller.start(gpa, no_interval));
    const no_metrics = Spec{ .pid = 1, .metrics = .initEmpty(), .interval_ms = 100 };
    try testing.expectError(error.NoMetrics, controller.start(gpa, no_metrics));
    try testing.expectError(error.RunUnknown, controller.stop(gpa, 42));
}

test "a run profiles this process into the server until it is stopped (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const fixture = try Fixture.create(16, 256 * 1024);
    defer fixture.destroy();

    const pid: u32 = @intCast(std.os.linux.getpid());
    const target = try fixture.controller.start(testing.allocator, .{
        .pid = pid,
        .metrics = cpu_only,
        .interval_ms = 100,
    });
    // Starting takes a while, and sampling needs something to sample.
    var waited: u32 = 0;
    while (fixture.windows_count(target) < 3) : (waited += 1) {
        if (waited > 200) return error.NoWindows;
        burn(50);
    }
    const reason = try fixture.controller.stop(testing.allocator, target);
    try testing.expectEqual(agent.StopReason.cancelled, reason);

    const server = &fixture.server;
    server.lock.lock();
    defer server.lock.unlock();
    const ring = &server.store.target_find(target).?.ring;
    var samples: u64 = 0;
    for (0..ring.count) |age| samples += ring.window_get(@intCast(age)).samples;
    std.debug.print("controller: {d} windows, {d} samples\n", .{ ring.count, samples });
    try testing.expect(samples >= 10);
    try testing.expect(ring.window_get(0).regions.len > 0);
    try testing.expectEqual(pid, ring.window_get(0).pid);
}

test "running is true while a run goes, false once it ended" {
    const fixture = try Fixture.create(2, 1024);
    defer fixture.destroy();
    const controller = &fixture.controller;

    // As root it runs for a second; without root it fails at once. Either way it ends.
    const target = try controller.start(testing.allocator, .{
        .pid = @intCast(std.os.linux.getpid()),
        .metrics = cpu_only,
        .interval_ms = 100,
        .duration_s = 1,
    });
    var waited: u32 = 0;
    while (controller.running(target)) : (waited += 1) {
        if (waited > 300) return error.RunNeverEnded;
        burn(10);
    }
    _ = controller.join(testing.allocator, target) catch {};
    try testing.expect(!controller.running(target));
}

test "the processes watch starts, refuses a second start, and stops when asked" {
    const fixture = try Fixture.create(2, 1024);
    defer fixture.destroy();
    const controller = &fixture.controller;
    const server = &fixture.server;

    try testing.expectError(error.NotWatchingProcs, controller.watch_procs_stop());
    try testing.expectEqual(
        @as(?agent.processes.Frame, null),
        try server.processes(testing.allocator),
    );

    try controller.watch_procs_start(testing.allocator, .{ .interval_ms = 100 });
    try testing.expect(controller.watch_procs_running());
    try testing.expectError(
        error.AlreadyWatchingProcs,
        controller.watch_procs_start(testing.allocator, .{ .interval_ms = 100 }),
    );

    burn(300); // The first look at once, then one every 100 ms.
    try testing.expect(server.processes_frames() >= 2);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frame = (try server.processes(arena.allocator())).?;
    const own: u32 = @intCast(std.os.linux.getpid());
    const found = for (frame.processes) |info| {
        if (info.pid == own) break true;
    } else false;
    try testing.expect(found);

    try testing.expectEqual(
        agent.processes.StopReason.cancelled,
        try controller.watch_procs_stop(),
    );
    try testing.expect(!controller.watch_procs_running());
}
