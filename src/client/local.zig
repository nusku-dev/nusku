//! The server and the agent in this one process: profiles a process, or watches the processes
//! of the machine, showing what is found so far to a live view.

const std = @import("std");
const server_lib = @import("server");
const protocol = @import("shared").protocol;
const log = @import("log").scope("prof");

const assert = std.debug.assert;
const Server = server_lib.Server;
const Controller = server_lib.Controller;

/// Windows are reserved up front, 128 KiB each: 3600 is 450 MiB.
const windows_max = 3600;
/// For a run with no end: ten minutes at one report a second.
const windows_unbounded = 600;

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(protocol.Metric),
    interval_ms: u32,
    /// 0: until the target exits, or Ctrl-C.
    duration_s: u32,
    /// The target was stopped (SIGSTOP) so that none of it runs unsampled: it is continued
    /// once sampling has started.
    continue_target: bool = false,
};

/// Shown the profile so far every `every_ms`, on the thread that called `profile`.
pub const Live = struct {
    context: *anyopaque,
    every_ms: u32,
    show: *const fn (context: *anyopaque, profile: *const server_lib.Profile, elapsed_ms: u64) void,
};

pub const Result = struct {
    reason: protocol.RunStop,
    profile: server_lib.Profile,
    /// From the run's start to its stop.
    elapsed_ms: u64,
};

/// The profile of the whole run, in `arena`. Ctrl-C stops the run, not the program.
pub fn profile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: Options,
    live: ?Live,
) !Result {
    assert(options.pid > 0);
    assert(options.interval_ms > 0);

    const backend = try Backend.create(gpa, windows_for(options));
    defer backend.destroy(gpa);
    const server = backend.server;
    const controller = backend.controller;

    const started_ms = monotonic_ms();
    const started = try controller.start(.{ .profile = .{
        .pid = options.pid,
        .metrics = options.metrics,
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
    } });
    const target = started.target.?;
    if (options.continue_target) {
        _ = std.os.linux.kill(@intCast(options.pid), std.os.linux.SIG.CONT);
    }
    interrupt_arm(controller);
    try wait(gpa, server, controller, started.job, target, started_ms, live);
    interrupt_release(); // Before the wait frees what the handler stops.
    const done = controller.wait(started.job);
    const elapsed_ms = monotonic_ms() - started_ms;

    return .{
        .reason = (try done).profile,
        // The last tables may still be building: `all_built` waits for them.
        .profile = try server.profile(arena, .{ .target = target }, .all_built),
        .elapsed_ms = elapsed_ms,
    };
}

/// One server and its controller, on the heap: they are large, and threads point into them.
const Backend = struct {
    server: *Server,
    controller: *Controller,

    fn create(gpa: std.mem.Allocator, windows: u32) !Backend {
        const server = try gpa.create(Server);
        errdefer gpa.destroy(server);
        try server.init(gpa, .{ .windows = .{
            .targets_max = 1,
            .windows_per_target_max = windows,
        } });
        errdefer server.deinit();
        const controller = try gpa.create(Controller);
        errdefer gpa.destroy(controller);
        try controller.init(gpa, server, .{ .jobs_max = 1 });
        return .{ .server = server, .controller = controller };
    }

    fn destroy(backend: Backend, gpa: std.mem.Allocator) void {
        backend.controller.deinit();
        gpa.destroy(backend.controller);
        backend.server.deinit();
        gpa.destroy(backend.server);
    }
};

/// The processes of this machine once, with their CPU: the second look, in `arena`.
pub fn processes(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    interval_ms: u32,
) !protocol.ProcessFrame {
    assert(interval_ms > 0);
    const backend = try Backend.create(gpa, 1);
    defer backend.destroy(gpa);
    const controller = backend.controller;

    const started = try controller.start(.{ .processes = .{ .interval_ms = interval_ms } });
    interrupt_arm(controller);

    // The first frame has no CPU: it is measured against the frame before. Each look is a
    // copy, so they go into a scratch arena, and only the one returned into `arena`.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    while ((try backend.server.processes(scratch.allocator())).frames < 2) {
        if (!controller.running(started.job)) break; // Ctrl-C, or the watch failed.
        sleep_ms(poll_ms);
        _ = scratch.reset(.retain_capacity);
    }
    interrupt_release();
    const latest = try backend.server.processes(arena);
    _ = try controller.stop(started.job);
    return latest.frame orelse error.Interrupted;
}

/// Shown each new frame, on the thread that called `processes_watch`. Valid until the next.
pub const ProcessesLive = struct {
    context: *anyopaque,
    show: *const fn (context: *anyopaque, frame: *const protocol.ProcessFrame) void,
};

/// A look every `interval_ms`, shown to `live` until Ctrl-C; not the first, which has no CPU.
pub fn processes_watch(gpa: std.mem.Allocator, interval_ms: u32, live: ProcessesLive) !void {
    assert(interval_ms > 0);
    const backend = try Backend.create(gpa, 1);
    defer backend.destroy(gpa);
    const controller = backend.controller;

    const started = try controller.start(.{ .processes = .{ .interval_ms = interval_ms } });
    interrupt_arm(controller);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var shown: u64 = 1; // Not the first.
    while (controller.running(started.job)) {
        sleep_ms(poll_ms);
        _ = arena.reset(.retain_capacity);
        const latest = try backend.server.processes(arena.allocator());
        if (latest.frames <= shown) continue;
        shown = latest.frames;
        const frame = latest.frame orelse continue;
        live.show(live.context, &frame);
    }
    interrupt_release();
    _ = try controller.stop(started.job);
}

fn monotonic_ms() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

/// Until the run ends, showing the profile so far to `live` every `every_ms`.
fn wait(
    gpa: std.mem.Allocator,
    server: *Server,
    controller: *Controller,
    job: server_lib.JobId,
    target: server_lib.TargetId,
    started_ms: u64,
    live: ?Live,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var next_ms = started_ms + if (live) |view| view.every_ms else 0;

    while (controller.running(job)) {
        sleep_ms(poll_ms);
        const view = live orelse continue;
        const now_ms = monotonic_ms();
        if (now_ms < next_ms) continue;
        next_ms = now_ms + view.every_ms;

        _ = arena.reset(.retain_capacity);
        // No window yet: the next view shows it.
        const query = server_lib.Query{ .target = target };
        const so_far = server.profile(arena.allocator(), query, .as_they_are) catch continue;
        view.show(view.context, &so_far, now_ms - started_ms);
    }
}

/// How late the run's end can be noticed.
const poll_ms = 50;

fn sleep_ms(ms: u64) void {
    const duration = std.os.linux.timespec{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast(ms % std.time.ms_per_s * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&duration, null);
}

fn windows_for(options: Options) u32 {
    if (options.duration_s == 0) return windows_unbounded;
    const reports = @as(u64, options.duration_s) * std.time.ms_per_s / options.interval_ms;
    // One report at the start, one at the end.
    return @intCast(@min(reports + 2, windows_max));
}

/// What Ctrl-C stops. Written outside the handler only.
var interrupt_controller: ?*const Controller = null;

fn interrupt_arm(controller: *const Controller) void {
    interrupt_controller = controller;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = interrupt_handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

/// The handler stays, so a late Ctrl-C (sudo passes one on twice) cannot end the program before
/// it prints.
fn interrupt_release() void {
    interrupt_controller = null;
}

fn interrupt_handle(_: std.posix.SIG) callconv(.c) void {
    if (interrupt_controller) |controller| controller.interrupt();
}

test "the windows kept cover the whole run, up to a limit" {
    const cpu = std.EnumSet(protocol.Metric).initOne(.cpu);
    const base = Options{ .pid = 1, .metrics = cpu, .interval_ms = 1000, .duration_s = 10 };
    try std.testing.expectEqual(@as(u32, 12), windows_for(base));

    var fast = base;
    fast.interval_ms = 100;
    try std.testing.expectEqual(@as(u32, 102), windows_for(fast));

    var long = base;
    long.duration_s = 24 * 3600;
    try std.testing.expectEqual(@as(u32, windows_max), windows_for(long));

    var unbounded = base;
    unbounded.duration_s = 0;
    try std.testing.expectEqual(@as(u32, windows_unbounded), windows_for(unbounded));
}
