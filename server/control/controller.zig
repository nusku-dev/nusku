//! Starts and stops profiling runs. This is the local backend: each run is `agent.profile`
//! on a thread of its own, feeding the server in the same process. A remote backend would
//! send the same `Spec` to an agent over the network; the server's `ingest` stays the same.
//!
//! Used from one control thread: `start`, `stop`, `join` and `deinit` do not run at the same
//! time as each other. The runs' own threads only call `Server.ingest`, which has its lock.

const std = @import("std");
const agent = @import("agent");
const Run = @import("run.zig").Run;
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;

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

    pub const Options = struct {
        /// Runs at once, one thread each.
        runs_max: u32 = 16,
    };

    pub fn init(controller: *Controller, gpa: std.mem.Allocator, server: *Server, options: Options) !void {
        assert(options.runs_max > 0);
        const runs = try gpa.alloc(Run, options.runs_max);
        for (runs) |*run| run.active = false;
        controller.* = .{ .server = server, .runs = runs };
    }

    /// Registers the process with the server and starts profiling it. Returns the id the
    /// server files its reports under. Errors that only the agent can see (no permission, the
    /// process is gone) come out of `stop` or `join`, not from here.
    pub fn start(controller: *Controller, gpa: std.mem.Allocator, spec: Spec) !TargetId {
        if (spec.pid == 0) return error.InvalidPid;
        if (spec.interval_ms == 0) return error.InvalidInterval;
        if (spec.metrics.count() == 0) return error.NoMetrics;
        const run = controller.run_free() orelse return error.RunsFull;

        const window_bytes_max = controller.server.store.ring_options.window_bytes_max;
        const scratch = try gpa.alignedAlloc(u8, .@"8", window_bytes_max);
        errdefer gpa.free(scratch);
        var cancel = try agent.Cancel.init();
        errdefer cancel.deinit();

        // A failed spawn leaves the target registered: there is no way to remove one yet.
        const target = try controller.server.target_add(gpa, spec.pid);

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
            .windows_dropped = 0,
            .result = error.NotFinished,
        };
        run.thread = std.Thread.spawn(.{}, Run.thread_main, .{ run, gpa }) catch |err| {
            run.active = false;
            return err;
        };
        return target;
    }

    /// Asks the run to stop and waits for it. Returns why it stopped, or the error that ended it.
    pub fn stop(controller: *Controller, gpa: std.mem.Allocator, target: TargetId) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        run.cancel.trigger();
        return controller.finish(gpa, run);
    }

    /// Waits for the run to end by itself (duration reached, or the target exited).
    pub fn join(controller: *Controller, gpa: std.mem.Allocator, target: TargetId) !agent.StopReason {
        const run = controller.run_find(target) orelse return error.RunUnknown;
        return controller.finish(gpa, run);
    }

    fn finish(controller: *Controller, gpa: std.mem.Allocator, run: *Run) !agent.StopReason {
        _ = controller;
        assert(run.active);
        run.thread.join();
        const result = run.result;
        run.cancel.deinit();
        gpa.free(run.scratch);
        run.active = false;
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

const testing = std.testing;

fn burn(ms: u64) void {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    const start_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
    var x: u64 = 0;
    while (true) {
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const now_ns = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
        if (now_ns - start_ns >= ms * std.time.ns_per_ms) break;
        x +%= 1;
    }
    std.mem.doNotOptimizeAway(x);
}

fn windows_count(server: *Server, target: TargetId) u32 {
    server.lock.lock();
    defer server.lock.unlock();
    return server.store.target_find(target).?.ring.count;
}

test "a bad spec and an unknown run are refused before anything starts" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1, .windows_per_target_max = 2, .window_bytes_max = 1024 });
    defer server.deinit(testing.allocator);
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .runs_max = 1 });
    defer controller.deinit(testing.allocator);

    const cpu = std.EnumSet(agent.Metric).initOne(.cpu);
    try testing.expectError(error.InvalidPid, controller.start(testing.allocator, .{ .pid = 0, .metrics = cpu, .interval_ms = 100 }));
    try testing.expectError(error.InvalidInterval, controller.start(testing.allocator, .{ .pid = 1, .metrics = cpu, .interval_ms = 0 }));
    try testing.expectError(error.NoMetrics, controller.start(testing.allocator, .{ .pid = 1, .metrics = .initEmpty(), .interval_ms = 100 }));
    try testing.expectError(error.RunUnknown, controller.stop(testing.allocator, 42));
}

test "a run profiles this process into the server until it is stopped (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1, .windows_per_target_max = 16, .window_bytes_max = 256 * 1024 });
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
