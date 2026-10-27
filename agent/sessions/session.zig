const std = @import("std");
const Cancel = @import("../clibs/cancel.zig").Cancel;
const proc_map = @import("process_maps.zig");
const maps_window = @import("maps_window.zig");
const oncpu = @import("oncpu/oncpu.zig");
const kernel = @import("kernel.zig");

const Region = maps_window.Region;

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

pub const Config = struct {
    pid: u32,
    /// Milliseconds between reports.
    interval_ms: u32,
    /// Seconds to run. 0 means until stopped.
    duration_s: u32,
    /// Lets another thread stop the run. Null means the run cannot be cancelled.
    cancel: ?*const Cancel = null,
};

// pub const Options = struct {
//     metrics: std.EnumSet(Metric),
//     config:Config,
// };

pub const Session = struct {
    /// Owns `table` and the mappings whose paths it borrows.
    arena_table: std.heap.ArenaAllocator,
    /// The target's executable regions from the last successful read.
    table: []const maps_window.Region,
    /// Owns the strings inside `kernel`.
    arena_kernel: std.heap.ArenaAllocator,
    kernel: kernel.Identity,
    /// Null when the cpu metric was not requested.
    cpu: ?oncpu.OncpuSession,

    pub fn init(gpa: std.mem.Allocator, metrics: std.EnumSet(Metric), pid: u32) !Session {
        // Validate everything first, while there is nothing to clean up.
        try isProcessAlive(pid);
        if (metrics.count() == 0) return error.NoMetrics;

        var requested = metrics.iterator();
        while (requested.next()) |metric| switch (metric) {
            .cpu => {},
            else => return error.MetricNotImplemented,
        };

        var arena_table = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_table.deinit();
        const mappings = try proc_map.read(arena_table.allocator(), pid);
        // A zombie has no mappings. Without a first table there is nothing to unwind against.
        if (mappings.len == 0) return error.ProcessNotFound;
        const table = try maps_window.regions_build(arena_table.allocator(), mappings, pid, &.{});

        // The kernel's identity cannot change while we run, so read it once.
        var arena_kernel = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_kernel.deinit();
        const kernel_identity = try kernel.read(arena_kernel.allocator());

        var cpu: ?oncpu.OncpuSession = null;
        errdefer if (cpu) |*cpu_loaded| cpu_loaded.deinit();
        if (metrics.contains(.cpu)) cpu = try oncpu.OncpuSession.init(gpa);

        return .{
            .arena_table = arena_table,
            .table = table,
            .arena_kernel = arena_kernel,
            .kernel = kernel_identity,
            .cpu = cpu,
        };
    }

    /// Releases everything, in the reverse order of init. Never fails.
    pub fn deinit(session: *Session) void {
        if (session.cpu) |*cpu| cpu.deinit();
        session.arena_kernel.deinit();
        session.arena_table.deinit();
        session.* = undefined;
    }
};

const sys = @import("../clibs/sys.zig");
const timer = @import("../clibs/timer.zig");

test "init rejects an empty metric set" {
    const metrics = std.EnumSet(Metric).initEmpty();
    try std.testing.expectError(
        error.NoMetrics,
        Session.init(std.testing.allocator, metrics, sys.currentPid()),
    );
}

test "init rejects a metric that is not implemented" {
    const metrics = std.EnumSet(Metric).initOne(.mem);
    try std.testing.expectError(
        error.MetricNotImplemented,
        Session.init(std.testing.allocator, metrics, sys.currentPid()),
    );
}

test "init on a zombie fails and leaks nothing" {
    const child = try sys.spawnSleeper();
    var reaped = false;
    defer if (!reaped) sys.reap(child);

    sys.kill9(child);
    try wait_for_zombie(child);

    const metrics = std.EnumSet(Metric).initOne(.cpu);
    // The errdefer on arena_table must free the empty mappings, or testing.allocator fails.
    try std.testing.expectError(
        error.ProcessNotFound,
        Session.init(std.testing.allocator, metrics, child),
    );

    sys.reap(child);
    reaped = true;
}

test "init and deinit on this process" {
    // Loading BPF needs root, or CAP_BPF and CAP_PERFMON.
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    const metrics = std.EnumSet(Metric).initOne(.cpu);
    var session = try Session.init(std.testing.allocator, metrics, sys.currentPid());
    defer session.deinit();

    try std.testing.expect(session.cpu != null);
    try std.testing.expect(session.table.len > 0);
}

/// Polls until the killed process has no mappings left, instead of sleeping and hoping.
fn wait_for_zombie(pid: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        const mappings = try proc_map.read(arena.allocator(), pid);
        if (mappings.len == 0) return;
        timer.sleepMs(10);
    }
    return error.ZombieTimeout;
}

fn isProcessAlive(pid: u32) !void {
    const isvalid = pid > 0 and pid <= std.math.maxInt(i32);
    if (!isvalid) {
        return error.InvalidPid;
    }
    try std.posix.kill(@intCast(pid), @enumFromInt(0));
}

test {
    _ = maps_window;
    _ = @import("build_id.zig");
    _ = @import("maps_window.zig");
}
