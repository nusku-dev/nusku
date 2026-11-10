//! The metrics layer: what is measured of the target, one window at a time.

const std = @import("std");
const protocol = @import("shared").protocol;
const os = @import("../os/os.zig");
const target_layer = @import("../target/target.zig");
const unwind_layer = @import("../unwind/unwind.zig");
const UnwindMaps = @import("unwind_maps.zig").UnwindMaps;
const cpu_collector = @import("cpu/collector.zig");
const log = @import("../log.zig").agent;

const Target = target_layer.Target;
const Unwind = unwind_layer.Unwind;
const CpuCollector = cpu_collector.Collector;

pub const Metric = protocol.Metric;
pub const CpuWindow = cpu_collector.Window;
pub const CpuStack = cpu_collector.Stack;
pub const CpuStop = cpu_collector.StopReason;

pub const Options = struct {
    metrics: std.EnumSet(Metric),
    cpu: cpu_collector.Options = .{},
};

/// Valid until the next `collect`.
pub const Windows = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    unwind: unwind_layer.Coverage,
    cpu: ?CpuWindow = null,
};

const refresh_gap_ns_min = 500 * std.time.ns_per_ms;

pub const Metrics = struct {
    unwind: Unwind,
    unwind_maps: UnwindMaps,
    cpu: ?CpuCollector,
    window_start_monotonic_ns: u64,
    window_start_unix_ns: u64,
    unknown_seen: u64,
    refreshed_ns: u64,

    /// Needs root, or CAP_BPF and CAP_PERFMON.
    pub fn init(
        metrics: *Metrics,
        gpa: std.mem.Allocator,
        target: *const Target,
        options: Options,
    ) !void {
        if (options.metrics.count() == 0) return error.NoMetrics;
        var asked = options.metrics.iterator();
        while (asked.next()) |metric| switch (metric) {
            .cpu => {},
            .offcpu, .mem, .io, .net, .locks, .sched => return error.MetricNotImplemented,
        };

        metrics.cpu = null;
        metrics.unknown_seen = 0;
        metrics.refreshed_ns = 0;
        try metrics.unwind.init(gpa, target.vdso_image());
        errdefer metrics.unwind.deinit(gpa);
        try metrics.unwind_maps.init();
        errdefer metrics.unwind_maps.deinit();
        try metrics.unwind.sync(gpa, target.pid, target.regions);
        try metrics.unwind_maps.write(target.pid, metrics.unwind.tables());

        if (options.metrics.contains(.cpu)) {
            metrics.cpu = @as(CpuCollector, undefined);
            try metrics.cpu.?.init(gpa, &metrics.unwind_maps, options.cpu);
        }
        errdefer if (metrics.cpu) |*cpu| cpu.deinit(gpa);

        metrics.window_start_monotonic_ns = os.timer.monotonic_ns();
        metrics.window_start_unix_ns = os.timer.realtime_ns();
        if (metrics.cpu) |*cpu| try cpu.start(target.pid);
        log.debug("metrics ready", .{ .pid = target.pid, .regions = target.regions.len });
    }

    pub fn deinit(metrics: *Metrics, gpa: std.mem.Allocator) void {
        if (metrics.cpu) |*cpu| cpu.deinit(gpa);
        metrics.unwind_maps.deinit();
        metrics.unwind.deinit(gpa);
        metrics.* = undefined;
    }

    pub fn tick(metrics: *Metrics, gpa: std.mem.Allocator, target: *Target) !void {
        const cpu = &(metrics.cpu orelse return);
        try cpu.tick();

        const unknown = try cpu.unknown_code();
        if (unknown == metrics.unknown_seen) return;
        const now_ns = os.timer.monotonic_ns();
        if (now_ns - metrics.refreshed_ns < refresh_gap_ns_min) return;
        metrics.unknown_seen = unknown;
        try metrics.refresh(gpa, target);
    }

    fn refresh(metrics: *Metrics, gpa: std.mem.Allocator, target: *Target) !void {
        metrics.refreshed_ns = os.timer.monotonic_ns();
        if (!try target.refresh()) return;
        try metrics.unwind.sync(gpa, target.pid, target.regions);
        try metrics.unwind_maps.write(target.pid, metrics.unwind.tables());
    }

    pub fn collect(metrics: *Metrics, gpa: std.mem.Allocator, target: *Target) !Windows {
        const now_monotonic_ns = os.timer.monotonic_ns();
        const now_unix_ns = os.timer.realtime_ns();
        std.debug.assert(now_monotonic_ns >= metrics.window_start_monotonic_ns);

        if (metrics.cpu) |*cpu| try cpu.generation_advance();
        try metrics.refresh(gpa, target);
        var windows = Windows{
            .start_unix_ns = metrics.window_start_unix_ns,
            .duration_ns = now_monotonic_ns - metrics.window_start_monotonic_ns,
            .unwind = metrics.unwind.coverage,
        };
        if (metrics.cpu) |*cpu| windows.cpu = try cpu.collect();

        metrics.window_start_monotonic_ns = now_monotonic_ns;
        metrics.window_start_unix_ns = now_unix_ns;
        return windows;
    }
};

const testing = std.testing;
const child_process = @import("../testing/process.zig");

test {
    _ = @import("bpf/libbpf.zig");
    _ = @import("bpf/loader.zig");
    _ = @import("bpf/map.zig");
    _ = @import("bpf/object.zig");
    _ = @import("bpf/program.zig");
    _ = @import("bpf/ring_buffer.zig");
    _ = @import("unwind_maps.zig");
    _ = cpu_collector;
    _ = @import("cpu/frame_cache.zig");
    _ = @import("cpu/sampler.zig");
    _ = @import("cpu/window.zig");
}

const cpu_only = Options{ .metrics = .initOne(.cpu) };

fn region_locate(regions: []const target_layer.Region, address: u64) ?*const target_layer.Region {
    for (regions) |*region| {
        if (address >= region.start and address < region.end) return region;
    }
    return null;
}

test "init refuses no metrics and unknown metrics, before loading anything" {
    var target = try Target.init(testing.allocator, os.process.current_pid());
    defer target.deinit(testing.allocator);
    var metrics: Metrics = undefined;
    const none = Options{ .metrics = .initEmpty() };
    try testing.expectError(error.NoMetrics, metrics.init(testing.allocator, &target, none));
    const mem = Options{ .metrics = .initOne(.mem) };
    const unknown = metrics.init(testing.allocator, &target, mem);
    try testing.expectError(error.MetricNotImplemented, unknown);
}

test "this process: one window per collect, with deep stacks (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var target = try Target.init(testing.allocator, os.process.current_pid());
    defer target.deinit(testing.allocator);
    const metrics = try testing.allocator.create(Metrics);
    defer testing.allocator.destroy(metrics);
    try metrics.init(testing.allocator, &target, cpu_only);
    defer metrics.deinit(testing.allocator);

    child_process.cpu_burn(300);
    try metrics.tick(testing.allocator, &target);
    const first = try metrics.collect(testing.allocator, &target);
    const first_cpu = first.cpu orelse return error.TestUnexpectedResult;
    const first_end = first.start_unix_ns + first.duration_ns;
    const first_samples = first_cpu.samples;

    try testing.expect(first.duration_ns >= 250 * std.time.ns_per_ms);
    try testing.expect(first.duration_ns < 1000 * std.time.ns_per_ms);
    try testing.expect(region_locate(target.regions, @intFromPtr(&region_locate)) != null);
    try testing.expectEqual(@as(u64, 0), first_cpu.loss.frames_missing);

    const cpu_ns = first_cpu.samples * std.time.ns_per_s / first_cpu.sample_hz;
    try testing.expect(cpu_ns >= first.duration_ns / 2);
    try testing.expect(cpu_ns <= first.duration_ns + first.duration_ns / 2);

    var deepest: usize = 0;
    for (first_cpu.stacks) |stack| deepest = @max(deepest, stack.user.len);
    std.debug.print("metrics: {d} samples in {d} ms, deepest user stack {d} frames\n", .{
        first_samples, first.duration_ns / std.time.ns_per_ms, deepest,
    });
    for (first_cpu.stops, 0..) |samples, index| {
        if (samples == 0) continue;
        const stop = std.enums.fromInt(CpuStop, index) orelse continue;
        std.debug.print("  stop {s}: {d} samples\n", .{ @tagName(stop), samples });
    }
    try testing.expect(deepest >= 3);
    const complete = first_cpu.stops[@intFromEnum(CpuStop.end)];
    try testing.expect(complete * 2 >= first_samples);

    child_process.cpu_burn(300);
    const second = try metrics.collect(testing.allocator, &target);
    const gap = @as(i64, @intCast(second.start_unix_ns)) - @as(i64, @intCast(first_end));
    try testing.expect(@abs(gap) < 5 * std.time.ns_per_ms);
    try testing.expect(second.cpu.?.samples > 0);
}
