//! Profiles a process of this machine: the server and the agent in this one process, the agent
//! on a thread of the server's controller. While the run goes (until its duration, the target
//! exiting, or Ctrl-C), it can hand the profile so far to a `Live` view; then it asks the
//! server for the profile of the whole run.

const std = @import("std");
const server_lib = @import("server");
const log = @import("log").scope("prof");

const assert = std.debug.assert;
const Server = server_lib.Server;
const Controller = server_lib.Controller;

/// The most windows kept, whatever the run: past it, the oldest windows go. Each window is
/// reserved up front (128 KiB), so this bounds the memory: 3600 is 450 MiB.
const windows_max = 3600;
/// Kept for a run with no end: ten minutes at one report a second.
const windows_unbounded = 600;

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(server_lib.Metric),
    interval_ms: u32,
    /// 0: until the target exits, or Ctrl-C.
    duration_s: u32,
};

/// Shown the profile as it grows, every `every_ms`, on the thread that called `profile`.
pub const Live = struct {
    context: *anyopaque,
    every_ms: u32,
    show: *const fn (context: *anyopaque, profile: *const server_lib.Profile, elapsed_ms: u64) void,
};

pub const Result = struct {
    reason: server_lib.StopReason,
    profile: server_lib.Profile,
    /// From the run's start to its stop.
    elapsed_ms: u64,
};

/// Runs the profile, and returns it in `arena`. Ctrl-C stops the run, not the program: the
/// profile of what was sampled until then is still returned.
pub fn profile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: Options,
    live: ?Live,
) !Result {
    assert(options.pid > 0);
    assert(options.interval_ms > 0);

    const windows = windows_for(options);
    // On the heap: the server and the controller are large, and threads point into them.
    const server = try gpa.create(Server);
    defer gpa.destroy(server);
    try server.init(gpa, .{ .targets_max = 1, .windows_per_target_max = windows });
    defer server.deinit(gpa);
    const controller = try gpa.create(Controller);
    defer gpa.destroy(controller);
    try controller.init(gpa, server, .{ .runs_max = 1 });
    defer controller.deinit(gpa);

    const started_ms = monotonic_ms();
    const target = try controller.start(gpa, .{
        .pid = options.pid,
        .metrics = options.metrics,
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
    });
    interrupt_arm(controller.cancel_of(target).?);
    try wait(gpa, server, controller, target, started_ms, live);
    const reason = controller.join(gpa, target);
    interrupt_release();
    const elapsed_ms = monotonic_ms() - started_ms;

    // Names come from tables the builder may still be making: wait for the last ones.
    server.builds_wait();
    return .{
        .reason = try reason,
        .profile = try server.profile(arena, .{
            .target = target,
            .from_unix_ns = 0,
            .to_unix_ns = std.math.maxInt(u64),
        }),
        .elapsed_ms = elapsed_ms,
    };
}

/// The name of process `pid` (its comm, what `ps` shows), in `buffer`, or null when it cannot
/// be read.
pub fn process_name(pid: u32, buffer: *[64]u8) ?[]const u8 {
    const linux = std.os.linux;
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/comm", .{pid}) catch unreachable;
    const opened = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const read = linux.read(fd, buffer, buffer.len);
    if (linux.errno(read) != .SUCCESS or read == 0) return null;
    return std.mem.trimEnd(u8, buffer[0..read], "\n");
}

fn monotonic_ms() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

/// Until the run ends: shows the profile so far to `live`, if there is one, every `every_ms`.
fn wait(
    gpa: std.mem.Allocator,
    server: *Server,
    controller: *Controller,
    target: server_lib.TargetId,
    started_ms: u64,
    live: ?Live,
) !void {
    // Each view's profile lives until the next one.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var next_ms = started_ms + if (live) |view| view.every_ms else 0;

    while (controller.running(target)) {
        sleep_ms(poll_ms);
        const view = live orelse continue;
        const now_ms = monotonic_ms();
        if (now_ms < next_ms) continue;
        next_ms = now_ms + view.every_ms;

        _ = arena.reset(.retain_capacity);
        // Too early for a window, or none yet: the next view shows it.
        const so_far = server.profile(arena.allocator(), .{
            .target = target,
            .from_unix_ns = 0,
            .to_unix_ns = std.math.maxInt(u64),
        }) catch continue;
        view.show(view.context, &so_far, now_ms - started_ms);
    }
}

/// How often the run is looked at: how late its end can be noticed.
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
    // The first report comes early, and the last one at the end: two more than the count.
    return @intCast(@min(reports + 2, windows_max));
}

/// What Ctrl-C stops while a run is going. Only ever written outside the handler.
var interrupt_cancel: ?*const server_lib.Cancel = null;

fn interrupt_arm(cancel: *const server_lib.Cancel) void {
    interrupt_cancel = cancel;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = interrupt_handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

/// The run is over: Ctrl-C has nothing to stop. The handler stays, so a Ctrl-C now (a late one,
/// or the same one twice: the terminal's and the one `sudo` passes on) does not end the
/// program before it prints the profile.
fn interrupt_release() void {
    interrupt_cancel = null;
}

/// In a signal handler: only the one write that `trigger` is.
fn interrupt_handle(_: std.posix.SIG) callconv(.c) void {
    if (interrupt_cancel) |cancel| cancel.trigger();
}

test "the windows kept cover the whole run, up to a limit" {
    const cpu = std.EnumSet(server_lib.Metric).initOne(.cpu);
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
