//! A profiling session: one target process, the metrics asked for, and what they share.
//!
//! What every metric shares lives here: the target's identity, its executable regions, and the
//! unwind tables of its binaries. Each metric is a collector with the same shape (init, start,
//! tick, collect, deinit), and each fills its own field of the report. A new metric is a new
//! collector and a new field; nothing else changes.

const std = @import("std");
const assert = std.debug.assert;
const timer = @import("os/timer.zig");
const process = @import("os/process.zig");
const process_maps = @import("target/process_maps.zig");
const regions_file = @import("target/regions.zig");
const kernel = @import("target/kernel.zig");
const tables_file = @import("unwind/tables.zig");
const collector_file = @import("cpu/collector.zig");

const Region = regions_file.Region;
const Tables = tables_file.Tables;
const CpuCollector = collector_file.Collector;

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

/// One window of every metric that was asked for. A metric's field is null when it was not.
///
/// Everything in it refers to the session's memory: it is valid until the next `report`.
pub const Report = struct {
    /// When the window began, in wall-clock nanoseconds since the Unix epoch.
    start_unix_ns: u64,
    /// How long the window lasted, on the monotonic clock.
    duration_ns: u64,
    pid: u32,
    /// The target's executable regions: the addresses in the stacks resolve against these.
    regions: []const Region,
    kernel: kernel.Identity,
    /// How much of the target's code has unwind tables.
    unwind: tables_file.Coverage,
    cpu: ?collector_file.Window = null,
};

pub const Session = struct {
    pid: u32,
    kernel: kernel.Identity,
    /// Owns `kernel`: read once, it cannot change while the agent runs.
    kernel_arena: std.heap.ArenaAllocator,
    /// The regions of the last successful read live in `regions_arenas[regions_current]`; the
    /// next read goes into the other one, and reuses the build IDs of these.
    regions: []const Region,
    regions_arenas: [2]std.heap.ArenaAllocator,
    regions_current: u1,
    tables: Tables,
    cpu: ?CpuCollector,
    window_start_monotonic_ns: u64,
    window_start_unix_ns: u64,

    pub const Options = struct {
        pid: u32,
        metrics: std.EnumSet(Metric),
        cpu: collector_file.Options = .{},
    };

    /// Needs root, or CAP_BPF and CAP_PERFMON. The session must stay at its address until
    /// `deinit`: the collectors point into it.
    pub fn init(session: *Session, gpa: std.mem.Allocator, options: Options) !void {
        // Check everything first, while there is nothing to clean up.
        if (!process.pid_valid(options.pid)) return error.InvalidPid;
        if (options.metrics.count() == 0) return error.NoMetrics;
        var metrics = options.metrics.iterator();
        while (metrics.next()) |metric| switch (metric) {
            .cpu => {},
            .offcpu, .mem, .io, .net, .locks, .sched => return error.MetricNotImplemented,
        };

        session.* = .{
            .pid = options.pid,
            .kernel = .{},
            .kernel_arena = .init(gpa),
            .regions = &.{},
            .regions_arenas = .{ .init(gpa), .init(gpa) },
            .regions_current = 0,
            .tables = undefined,
            .cpu = null,
            .window_start_monotonic_ns = 0,
            .window_start_unix_ns = 0,
        };
        errdefer session.arenas_deinit();

        session.kernel = try kernel.read(session.kernel_arena.allocator());
        // Without a first table of regions there is nothing to unwind against.
        if (!try session.regions_refresh_read()) return error.ProcessNotFound;

        try session.tables.init(gpa);
        errdefer session.tables.deinit(gpa);
        try session.tables.sync(gpa, session.pid, session.regions);

        if (options.metrics.contains(.cpu)) {
            session.cpu = @as(CpuCollector, undefined);
            try session.cpu.?.init(gpa, &session.tables, options.cpu);
        }
        errdefer if (session.cpu) |*cpu| cpu.deinit(gpa);

        // The first window begins just before sampling starts, so it is never shorter.
        session.window_start_monotonic_ns = timer.monotonic_ns();
        session.window_start_unix_ns = timer.realtime_ns();
        if (session.cpu) |*cpu| try cpu.start(session.pid);
    }

    /// Releases everything, in the reverse order of init. Never fails.
    pub fn deinit(session: *Session, gpa: std.mem.Allocator) void {
        if (session.cpu) |*cpu| cpu.deinit(gpa);
        session.tables.deinit(gpa);
        session.arenas_deinit();
        session.* = undefined;
    }

    fn arenas_deinit(session: *Session) void {
        session.regions_arenas[1].deinit();
        session.regions_arenas[0].deinit();
        session.kernel_arena.deinit();
    }

    /// Drains the kernel's buffers between reports, so they do not fill up. Cheap when they
    /// are empty: call it at a fixed pace, not only when something happened.
    pub fn tick(session: *Session) !void {
        if (session.cpu) |*cpu| try cpu.tick();
    }

    /// What was sampled since the previous report, or since `init`.
    pub fn report(session: *Session, gpa: std.mem.Allocator) !Report {
        const now_monotonic_ns = timer.monotonic_ns();
        const now_unix_ns = timer.realtime_ns();
        assert(now_monotonic_ns >= session.window_start_monotonic_ns);

        if (session.cpu) |*cpu| try cpu.generation_advance();
        // Also the grace time between the generation's advance and its drain.
        if (try session.regions_refresh_read()) {
            try session.tables.sync(gpa, session.pid, session.regions);
        }

        var result = Report{
            .start_unix_ns = session.window_start_unix_ns,
            .duration_ns = now_monotonic_ns - session.window_start_monotonic_ns,
            .pid = session.pid,
            .regions = session.regions,
            .kernel = session.kernel,
            .unwind = session.tables.coverage,
        };
        if (session.cpu) |*cpu| result.cpu = try cpu.collect();

        // Only now does the next window begin.
        session.window_start_monotonic_ns = now_monotonic_ns;
        session.window_start_unix_ns = now_unix_ns;
        return result;
    }

    /// Reads the target's regions into the spare arena, and makes them current. False when the
    /// target has exited: the last regions are kept, so a final report can still use them.
    fn regions_refresh_read(session: *Session) !bool {
        const spare = session.regions_current +% 1;
        const arena = &session.regions_arenas[spare];
        // Keeping the capacity, a steady target's reads stop allocating after the first.
        _ = arena.reset(.retain_capacity);

        const mappings = process_maps.read(arena.allocator(), session.pid) catch |err| {
            switch (err) {
                error.NotFound, error.ProcessNotFound => return false,
                else => return err,
            }
        };
        // A zombie has no mappings left.
        if (mappings.len == 0) return false;

        session.regions = try regions_file.build(
            arena.allocator(),
            mappings,
            session.pid,
            session.regions,
        );
        session.regions_current = spare;
        return true;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("testing/process.zig");

fn wait_for_zombie(pid: u32) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Polls until the killed process has no mappings left, instead of sleeping and hoping.
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        _ = arena.reset(.retain_capacity);
        const mappings = try process_maps.read(arena.allocator(), pid);
        if (mappings.len == 0) return;
        timer.sleep_ms(10);
    }
    return error.ZombieTimeout;
}

/// The region that holds `address`, or null.
fn region_locate(regions: []const Region, address: u64) ?*const Region {
    for (regions) |*region| {
        if (address >= region.start and address < region.end) return region;
    }
    return null;
}

const Set = std.EnumSet(Metric);

test "init refuses no metrics, unknown metrics, and invalid pids, before loading anything" {
    var session: Session = undefined;
    const pid = process.current_pid();
    try testing.expectError(error.NoMetrics, session.init(testing.allocator, .{
        .pid = pid,
        .metrics = Set.initEmpty(),
    }));
    try testing.expectError(error.MetricNotImplemented, session.init(testing.allocator, .{
        .pid = pid,
        .metrics = Set.initOne(.mem),
    }));
    try testing.expectError(error.InvalidPid, session.init(testing.allocator, .{
        .pid = 0,
        .metrics = Set.initOne(.cpu),
    }));
}

test "init on a zombie fails, and leaks nothing" {
    const child = try child_process.sleeper_spawn();
    var reaped = false;
    defer if (!reaped) child_process.child_reap(child);

    child_process.child_kill(child);
    try wait_for_zombie(child);

    // The errdefers must free the arenas, or testing.allocator reports a leak.
    var session: Session = undefined;
    try testing.expectError(error.ProcessNotFound, session.init(testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
    }));
    child_process.child_reap(child);
    reaped = true;
}

test "this process: one window per report, with deep stacks (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    const session = try testing.allocator.create(Session);
    defer testing.allocator.destroy(session);
    try session.init(testing.allocator, .{
        .pid = process.current_pid(),
        .metrics = Set.initOne(.cpu),
    });
    defer session.deinit(testing.allocator);

    child_process.cpu_burn(300);
    try session.tick();
    const first = try session.report(testing.allocator);
    const first_cpu = first.cpu orelse return error.TestUnexpectedResult;
    const first_end = first.start_unix_ns + first.duration_ns;
    const first_samples = first_cpu.samples;
    const first_duration_ns = first.duration_ns;

    // Each window is about 300 ms long.
    try testing.expect(first.duration_ns >= 250 * std.time.ns_per_ms);
    try testing.expect(first.duration_ns < 1000 * std.time.ns_per_ms);
    try testing.expect(first.kernel.release.len > 0);
    try testing.expectEqual(process.current_pid(), first.pid);
    try testing.expect(region_locate(first.regions, @intFromPtr(&region_locate)) != null);
    try testing.expectEqual(@as(u64, 0), first_cpu.loss.frames_missing);

    // samples / hz is CPU time: one busy thread uses about the wall time it ran.
    const cpu_ns = first_cpu.samples * std.time.ns_per_s / first_cpu.sample_hz;
    try testing.expect(cpu_ns >= first.duration_ns / 2);
    try testing.expect(cpu_ns <= first.duration_ns + first.duration_ns / 2);

    // With the tables loaded, a stack has its callers, not just the running instruction.
    var deepest: usize = 0;
    for (first_cpu.stacks) |stack| deepest = @max(deepest, stack.user.len);
    std.debug.print("session: {d} samples in {d} ms, deepest user stack {d} frames\n", .{
        first_samples, first_duration_ns / std.time.ns_per_ms, deepest,
    });
    // Where the walks stopped, so a failure below says why.
    for (first_cpu.stops, 0..) |samples, index| {
        if (samples == 0) continue;
        const stop = std.enums.fromInt(collector_file.StopReason, index) orelse continue;
        std.debug.print("  stop {s}: {d} samples\n", .{ @tagName(stop), samples });
    }
    try testing.expect(deepest >= 3);
    // The burner runs in this binary, which has a table, so its walks reach the outermost frame.
    const complete = first_cpu.stops[@intFromEnum(collector_file.StopReason.end)];
    try testing.expect(complete * 2 >= first_samples); // Most stacks are complete.

    child_process.cpu_burn(300);
    const second = try session.report(testing.allocator);
    // The second window begins where the first ended, within 5 ms.
    const gap = @as(i64, @intCast(second.start_unix_ns)) - @as(i64, @intCast(first_end));
    try testing.expect(@abs(gap) < 5 * std.time.ns_per_ms);
    try testing.expect(second.cpu.?.samples > 0);
}
