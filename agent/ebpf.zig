//! The ebpf layer: programs loaded into the kernel, and what they measure. Each metric is a
//! folder under ebpf/ and a field of `Ebpf`: cpu/ today; offcpu/, mem/ and the others go next
//! to it the same way. The target's unwind tables are mirrored into the kernel for the programs
//! that walk stacks. Stands on os, target and unwind.
//!   bpf/     loading BPF objects and talking to their maps
//!   kernel/  the programs themselves, compiled for BPF and embedded
//!   cpu/     the on-CPU sampler, its frame cache, and its windows

const std = @import("std");
const protocol = @import("shared").protocol;
const os = @import("os.zig");
const target_layer = @import("target.zig");
const unwind_layer = @import("unwind.zig");
const UnwindMaps = @import("ebpf/unwind_maps.zig").UnwindMaps;
const cpu_collector = @import("ebpf/cpu/collector.zig");
const log = @import("log.zig").agent;

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

/// One window of each metric asked for; null for the others. Valid until the next `collect`.
pub const Windows = struct {
    /// When the window began, in wall-clock nanoseconds since the Unix epoch.
    start_unix_ns: u64,
    /// How long it lasted, on the monotonic clock.
    duration_ns: u64,
    /// How much of the target's code has unwind tables.
    unwind: unwind_layer.Coverage,
    cpu: ?CpuWindow = null,
};

pub const Ebpf = struct {
    unwind: Unwind,
    unwind_maps: UnwindMaps,
    cpu: ?CpuCollector,
    window_start_monotonic_ns: u64,
    window_start_unix_ns: u64,

    /// Loads the programs and starts measuring `target`. Needs root, or CAP_BPF and
    /// CAP_PERFMON. Must stay at its address until `deinit`: the collectors point into it.
    pub fn init(
        ebpf: *Ebpf,
        gpa: std.mem.Allocator,
        target: *const Target,
        options: Options,
    ) !void {
        // Checked first, while there is nothing to clean up.
        if (options.metrics.count() == 0) return error.NoMetrics;
        var metrics = options.metrics.iterator();
        while (metrics.next()) |metric| switch (metric) {
            .cpu => {},
            .offcpu, .mem, .io, .net, .locks, .sched => return error.MetricNotImplemented,
        };

        ebpf.cpu = null;
        try ebpf.unwind.init(gpa, target.vdso_image());
        errdefer ebpf.unwind.deinit(gpa);
        try ebpf.unwind_maps.init();
        errdefer ebpf.unwind_maps.deinit();
        try ebpf.unwind.sync(gpa, target.pid, target.regions);
        try ebpf.unwind_maps.write(target.pid, ebpf.unwind.tables());

        if (options.metrics.contains(.cpu)) {
            ebpf.cpu = @as(CpuCollector, undefined);
            try ebpf.cpu.?.init(gpa, &ebpf.unwind_maps, options.cpu);
        }
        errdefer if (ebpf.cpu) |*cpu| cpu.deinit(gpa);

        // The first window begins just before sampling starts, so it is never shorter.
        ebpf.window_start_monotonic_ns = os.timer.monotonic_ns();
        ebpf.window_start_unix_ns = os.timer.realtime_ns();
        if (ebpf.cpu) |*cpu| try cpu.start(target.pid);
        log.debug("ebpf ready", .{ .pid = target.pid, .regions = target.regions.len });
    }

    /// In the reverse order of `init`. Never fails.
    pub fn deinit(ebpf: *Ebpf, gpa: std.mem.Allocator) void {
        if (ebpf.cpu) |*cpu| cpu.deinit(gpa);
        ebpf.unwind_maps.deinit();
        ebpf.unwind.deinit(gpa);
        ebpf.* = undefined;
    }

    /// Drains the kernel's buffers, so they do not fill up between two windows. Cheap when they
    /// are empty: call it at a steady pace.
    pub fn tick(ebpf: *Ebpf) !void {
        if (ebpf.cpu) |*cpu| try cpu.tick();
    }

    /// What was measured since the last window, or since `init`. Refreshes the target's regions
    /// on the way, and the unwind tables if they changed.
    pub fn collect(ebpf: *Ebpf, gpa: std.mem.Allocator, target: *Target) !Windows {
        const now_monotonic_ns = os.timer.monotonic_ns();
        const now_unix_ns = os.timer.realtime_ns();
        std.debug.assert(now_monotonic_ns >= ebpf.window_start_monotonic_ns);

        if (ebpf.cpu) |*cpu| try cpu.generation_advance();
        // Also the grace time between the generation's advance and its drain.
        if (try target.refresh()) {
            try ebpf.unwind.sync(gpa, target.pid, target.regions);
            try ebpf.unwind_maps.write(target.pid, ebpf.unwind.tables());
        }
        var windows = Windows{
            .start_unix_ns = ebpf.window_start_unix_ns,
            .duration_ns = now_monotonic_ns - ebpf.window_start_monotonic_ns,
            .unwind = ebpf.unwind.coverage,
        };
        if (ebpf.cpu) |*cpu| windows.cpu = try cpu.collect();

        // Only now does the next window begin.
        ebpf.window_start_monotonic_ns = now_monotonic_ns;
        ebpf.window_start_unix_ns = now_unix_ns;
        return windows;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("testing/process.zig");

test {
    _ = @import("ebpf/bpf/libbpf.zig");
    _ = @import("ebpf/bpf/loader.zig");
    _ = @import("ebpf/bpf/map.zig");
    _ = @import("ebpf/bpf/object.zig");
    _ = @import("ebpf/bpf/program.zig");
    _ = @import("ebpf/bpf/ring_buffer.zig");
    _ = @import("ebpf/unwind_maps.zig");
    _ = cpu_collector;
    _ = @import("ebpf/cpu/frame_cache.zig");
    _ = @import("ebpf/cpu/sampler.zig");
    _ = @import("ebpf/cpu/window.zig");
}

const cpu_only = Options{ .metrics = .initOne(.cpu) };

/// The region that holds `address`, or null.
fn region_locate(regions: []const target_layer.Region, address: u64) ?*const target_layer.Region {
    for (regions) |*region| {
        if (address >= region.start and address < region.end) return region;
    }
    return null;
}

test "init refuses no metrics and unknown metrics, before loading anything" {
    var target = try Target.init(testing.allocator, os.process.current_pid());
    defer target.deinit(testing.allocator);
    var ebpf: Ebpf = undefined;
    const none = Options{ .metrics = .initEmpty() };
    try testing.expectError(error.NoMetrics, ebpf.init(testing.allocator, &target, none));
    const mem = Options{ .metrics = .initOne(.mem) };
    try testing.expectError(error.MetricNotImplemented, ebpf.init(testing.allocator, &target, mem));
}

test "this process: one window per collect, with deep stacks (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var target = try Target.init(testing.allocator, os.process.current_pid());
    defer target.deinit(testing.allocator);
    const ebpf = try testing.allocator.create(Ebpf);
    defer testing.allocator.destroy(ebpf);
    try ebpf.init(testing.allocator, &target, cpu_only);
    defer ebpf.deinit(testing.allocator);

    child_process.cpu_burn(300);
    try ebpf.tick();
    const first = try ebpf.collect(testing.allocator, &target);
    const first_cpu = first.cpu orelse return error.TestUnexpectedResult;
    const first_end = first.start_unix_ns + first.duration_ns;
    const first_samples = first_cpu.samples;

    // Each window is about 300 ms long.
    try testing.expect(first.duration_ns >= 250 * std.time.ns_per_ms);
    try testing.expect(first.duration_ns < 1000 * std.time.ns_per_ms);
    try testing.expect(region_locate(target.regions, @intFromPtr(&region_locate)) != null);
    try testing.expectEqual(@as(u64, 0), first_cpu.loss.frames_missing);

    // samples / hz is CPU time: one busy thread uses about the wall time it ran.
    const cpu_ns = first_cpu.samples * std.time.ns_per_s / first_cpu.sample_hz;
    try testing.expect(cpu_ns >= first.duration_ns / 2);
    try testing.expect(cpu_ns <= first.duration_ns + first.duration_ns / 2);

    // With the tables loaded, a stack has its callers, not just the running instruction.
    var deepest: usize = 0;
    for (first_cpu.stacks) |stack| deepest = @max(deepest, stack.user.len);
    std.debug.print("ebpf: {d} samples in {d} ms, deepest user stack {d} frames\n", .{
        first_samples, first.duration_ns / std.time.ns_per_ms, deepest,
    });
    // Where the walks stopped, so a failure below says why.
    for (first_cpu.stops, 0..) |samples, index| {
        if (samples == 0) continue;
        const stop = std.enums.fromInt(CpuStop, index) orelse continue;
        std.debug.print("  stop {s}: {d} samples\n", .{ @tagName(stop), samples });
    }
    try testing.expect(deepest >= 3);
    // The burner runs in this binary, which has a table, so its walks reach the outermost frame.
    const complete = first_cpu.stops[@intFromEnum(CpuStop.end)];
    try testing.expect(complete * 2 >= first_samples); // Most stacks are complete.

    child_process.cpu_burn(300);
    const second = try ebpf.collect(testing.allocator, &target);
    // The second window begins where the first ended, within 5 ms.
    const gap = @as(i64, @intCast(second.start_unix_ns)) - @as(i64, @intCast(first_end));
    try testing.expect(@abs(gap) < 5 * std.time.ns_per_ms);
    try testing.expect(second.cpu.?.samples > 0);
}
