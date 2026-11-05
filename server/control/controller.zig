//! Starts and stops profiling runs. This is the local backend: each run is `agent.profile`
//! on a thread of its own, feeding the server in the same process. A remote backend would
//! send the same `Spec` to an agent over the network; the server's `ingest` stays the same.
//!
//! Used from one control thread: `start`, `stop`, `join` and `deinit` do not run at the same
//! time as each other. The runs' own threads only call the server, which has its lock.

const std = @import("std");
const agent = @import("agent");
const Run = @import("run.zig").Run;
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;
const Upload = @import("../symbolize/upload.zig").Upload;
const log = @import("../log.zig").server;

const assert = std.debug.assert;

pub const Spec = struct {
    pid: u32,
    metrics: std.EnumSet(agent.Metric),
    /// Milliseconds between reports.
    interval_ms: u32,
    /// Seconds to run. 0 runs until the target exits or `stop`.
    duration_s: u32 = 0,
};

pub const Controller = struct {
    server: *Server,
    runs: []Run,
    upload_bytes_max: u64,

    pub const Options = struct {
        /// Runs at once, one thread each.
        runs_max: u32 = 16,
        /// What the buffers of one binary upload may take, per run. Allocated only when a
        /// binary of that size actually arrives.
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
            .upload_bytes_max = options.upload_bytes_max,
        };
    }

    /// Registers the process with the server and starts profiling it. Returns the id the
    /// server files its reports under. Errors that only the agent can see (no permission, the
    /// process is gone) come out of `stop` or `join`, not from here.
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

    /// Asks the run to stop and waits for it. Returns why it stopped, or the error that ended it.
    pub fn stop(
        controller: *Controller,
        gpa: std.mem.Allocator,
        target: TargetId,
    ) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        run.cancel.trigger();
        return controller.finish(gpa, run);
    }

    /// Whether the run is still going: when it is not, `join` returns at once. For a caller that
    /// does something else while it waits (shows the profile as it grows, say).
    pub fn running(controller: *Controller, target: TargetId) bool {
        const run = controller.run_find(target) orelse return false;
        return !run.finished.load(.acquire);
    }

    /// What stops the run, for a caller that must stop it from where `stop` cannot be called:
    /// a signal handler (`trigger` is one write). Good until `stop` or `join` returns.
    pub fn cancel_of(controller: *Controller, target: TargetId) ?*const agent.Cancel {
        const run = controller.run_find(target) orelse return null;
        return &run.cancel;
    }

    /// Waits for the run to end by itself (duration reached, or the target exited).
    pub fn join(
        controller: *Controller,
        gpa: std.mem.Allocator,
        target: TargetId,
    ) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        return controller.finish(gpa, run);
    }

    fn finish(controller: *Controller, gpa: std.mem.Allocator, run: *Run) !agent.StopReason {
        assert(run.active);
        run.thread.join();
        // Its windows stay for queries, until a new target needs the room. Already gone only
        // if someone removed it by hand.
        controller.server.target_finish(run.target) catch {};
        const result = run.result;
        run.cancel.deinit();
        gpa.free(run.scratch);
        // The agent ends a transfer before it returns; this is only in case it did not.
        run.binary_abort();
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

    /// Stops every run that is still going, then frees the controller.
    pub fn deinit(controller: *Controller, gpa: std.mem.Allocator) void {
        for (controller.runs) |*run| {
            if (!run.active) continue;
            run.cancel.trigger();
            _ = controller.finish(gpa, run) catch {};
        }
        gpa.free(controller.runs);
        controller.* = undefined;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const burn = @import("../testing/burn.zig").burn;

fn windows_count(server: *Server, target: TargetId) u32 {
    server.lock.lock();
    defer server.lock.unlock();
    return server.store.target_find(target).?.ring.count;
}

test "a bad spec and an unknown run are refused before anything starts" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .runs_max = 1 });
    defer controller.deinit(testing.allocator);

    const gpa = testing.allocator;
    const cpu = std.EnumSet(agent.Metric).initOne(.cpu);
    const no_pid = Spec{ .pid = 0, .metrics = cpu, .interval_ms = 100 };
    try testing.expectError(error.InvalidPid, controller.start(gpa, no_pid));
    const no_interval = Spec{ .pid = 1, .metrics = cpu, .interval_ms = 0 };
    try testing.expectError(error.InvalidInterval, controller.start(gpa, no_interval));
    const no_metrics = Spec{ .pid = 1, .metrics = .initEmpty(), .interval_ms = 100 };
    try testing.expectError(error.NoMetrics, controller.start(gpa, no_metrics));
    try testing.expectError(error.RunUnknown, controller.stop(gpa, 42));
}

test "a run profiles this process into the server until it is stopped (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 16,
        .window_bytes_max = 256 * 1024,
    });
    defer server.deinit(testing.allocator);
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .runs_max = 1 });
    defer controller.deinit(testing.allocator);

    const pid: u32 = @intCast(std.os.linux.getpid());
    const target = try controller.start(testing.allocator, .{
        .pid = pid,
        .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
        .interval_ms = 100,
    });

    // Starting takes a while (loading the program, building the tables of this binary), and
    // sampling needs something to sample: burn until the windows arrive.
    var waited: u32 = 0;
    while (windows_count(&server, target) < 3) : (waited += 1) {
        if (waited > 200) return error.NoWindows;
        burn(50);
    }

    const reason = try controller.stop(testing.allocator, target);
    try testing.expectEqual(agent.StopReason.cancelled, reason);

    server.lock.lock();
    defer server.lock.unlock();
    const ring = &server.store.target_find(target).?.ring;
    var samples: u64 = 0;
    var age: u32 = 0;
    while (age < ring.count) : (age += 1) samples += ring.window_get(age).samples;
    std.debug.print("controller: {d} windows, {d} samples\n", .{ ring.count, samples });
    try testing.expect(samples >= 10);
    try testing.expect(ring.window_get(0).regions.len > 0);
    try testing.expectEqual(pid, ring.window_get(0).pid);
}

test "running is true while a run goes, false once it ended" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .runs_max = 1 });
    defer controller.deinit(testing.allocator);

    // As root it profiles this process for a second; without root it fails at once. Either
    // way it ends, and `running` says so before `join` is called.
    const target = try controller.start(testing.allocator, .{
        .pid = @intCast(std.os.linux.getpid()),
        .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
        .interval_ms = 100,
        .duration_s = 1,
    });
    var waited: u32 = 0;
    while (controller.running(target)) : (waited += 1) {
        if (waited > 300) return error.RunNeverEnded;
        burn(10);
    }
    _ = controller.join(testing.allocator, target) catch {};
    try testing.expect(!controller.running(target)); // Joined: no run of that id any more.
}
