const std = @import("std");
const Cancel = @import("../clibs/cancel.zig").Cancel;
const proc_map = @import("process_maps.zig");
const maps_window = @import("maps_window.zig");
const oncpu = @import("oncpu/oncpu.zig");
const kernel = @import("kernel.zig");
const unwind = @import("../unwind/root.zig");
const unwind_entry = @import("unwind_entry.zig");

const Region = maps_window.Region;
const ProcessEntry = unwind.procmap.ProcessEntry;
const CpuWindow = oncpu.Window;

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

const sample_hz = 99;

/// One tick's worth of data. A metric's field is null when it was not requested.
pub const Report = struct {
    /// When the window began, as wall-clock nanoseconds since the Unix epoch.
    start_unix_ns: u64,
    /// How long the window lasted, measured on the monotonic clock.
    duration_ns: u64,
    pid: u32,
    /// CPU samples taken per second on each CPU. `samples / cpu_sample_hz` is CPU seconds.
    /// 0 when the cpu metric was not requested.
    cpu_sample_hz: u32 = 0,
    /// The target's executable regions. The addresses in the stacks are resolved against these.
    regions: []const maps_window.Region = &.{},
    kernel: kernel.Identity = .{},
    cpu: ?CpuWindow = null,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    pid: u32,
    registry: unwind.registry.Registry,
    bpf_tables: oncpu.TableMaps,
    entry: *ProcessEntry,
    /// Index of the first module the kernel does not have yet.
    modules_written: usize,

    kernel: kernel.Identity,
    arena_kernel: std.heap.ArenaAllocator,

    /// Owns `table` and the mappings whose paths it borrows.
    arena_table: std.heap.ArenaAllocator,
    /// The target's executable regions from the last successful read.
    table: []const maps_window.Region,

    window_start_mono_ns: u64,
    window_start_unix_ns: u64,
    table_failures: u32 = 0,
    cpu: ?oncpu.OncpuSession = null,

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

        var registry: unwind.registry.Registry = undefined;
        try registry.init(gpa, .{ .rows_max = 262_144, .modules_max = 256 });
        errdefer registry.deinit(gpa);

        var bpf_tables = try cpu.?.build_unwind_maps(gpa);
        errdefer bpf_tables.deinit(gpa);

        const entry = try gpa.create(ProcessEntry);
        errdefer gpa.destroy(entry);
        {
            const built = try unwind_entry.build_unwind_entry(gpa, &registry, pid, table);
            try bpf_tables.writeModulesFrom(registry.set, 0);
            try bpf_tables.writeProcess(pid, built.entry);
            entry.* = built.entry;
        }

        // The first window begins just before the attach, so it is never shorter than the sampling.
        const began_mono = timer.monotonicNs();
        const began_unix = timer.realtimeNs();
        if (cpu) |*c| try c.start(pid, sample_hz);

        return .{
            .gpa = gpa,
            .pid = pid,
            .registry = registry,
            .bpf_tables = bpf_tables,
            .entry = entry,
            .modules_written = registry.set.modules_count,
            .kernel = kernel_identity,
            .arena_kernel = arena_kernel,
            .arena_table = arena_table,
            .table = table,
            .window_start_mono_ns = began_mono,
            .window_start_unix_ns = began_unix,
            .cpu = cpu,
        };
    }

    /// What was sampled since the previous report (or since `init`). Everything inside the
    /// result lives in `arena`; release it by resetting or deinitializing the arena.
    pub fn report(self: *Session, arena: std.mem.Allocator) !Report {
        const now_mono = timer.monotonicNs();
        const now_unix = timer.realtimeNs();

        var result = Report{
            .start_unix_ns = self.window_start_unix_ns,
            .duration_ns = now_mono - self.window_start_mono_ns,
            .pid = self.pid,
            .kernel = self.kernel,
        };
        if (self.cpu) |*cpu| {
            result.cpu = try cpu.collect(arena);
            result.cpu_sample_hz = sample_hz;
        }

        // If the process is gone, keep the window we just collected and the last known regions.
        if (proc_map.read(arena, self.pid)) |mappings| {
            if (mappings.len > 0) {
                result.regions = try maps_window.regions_build(arena, mappings, self.pid, self.table);
                self.refreshTables(result.regions) catch {
                    self.table_failures += 1;
                };
            } else {
                result.regions = self.table;
            }
        } else |_| {
            result.regions = self.table;
        }

        // Only now does the next window begin.
        self.window_start_mono_ns = now_mono;
        self.window_start_unix_ns = now_unix;
        return result;
    }

    /// Loads the tables of binaries the target mapped since the last call, and rewrites its
    /// mapping list when it changed. Binaries go in first, so the list never points at a missing one.
    fn refreshTables(self: *Session, regions: []const maps_window.Region) !void {
        const built = try unwind_entry.build_unwind_entry(self.gpa, &self.registry, self.pid, regions);
        try self.bpf_tables.writeModulesFrom(self.registry.set, self.modules_written);
        self.modules_written = self.registry.set.modules_count;
        if (!std.mem.eql(u8, std.mem.asBytes(&built.entry), std.mem.asBytes(self.entry))) {
            try self.bpf_tables.writeProcess(self.pid, built.entry);
            self.entry.* = built.entry;
        }
    }

    /// Releases everything, in the reverse order of init. Never fails.
    pub fn deinit(session: *Session) void {
        const gpa = session.gpa;
        session.bpf_tables.deinit(gpa);
        session.registry.deinit(gpa);
        gpa.destroy(session.entry);
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

const Set = std.EnumSet(Metric);

fn burn(ms: u64) void {
    const until = timer.monotonicNs() + ms * std.time.ns_per_ms;
    var x: u64 = 0;
    while (timer.monotonicNs() < until) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

/// The region that holds `address`, or null.
fn locate(regions: []const maps_window.Region, address: u64) ?*const maps_window.Region {
    for (regions) |*r| {
        if (address >= r.start and address < r.end) return r;
    }
    return null;
}

test "session samples this process and reports one window per call (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    var session = try Session.init(std.testing.allocator, Set.initOne(.cpu), sys.currentPid());
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    burn(300);
    const first = try session.report(arena.allocator());
    burn(300);
    const second = try session.report(arena.allocator());

    try std.testing.expect(first.kernel.release.len > 0);
    try std.testing.expectEqualStrings(first.kernel.release, second.kernel.release);
    try std.testing.expect(first.cpu != null and second.cpu != null);

    // Each window is about 300 ms long, and the second begins where the first ended.
    try std.testing.expect(first.duration_ns >= 250_000_000 and first.duration_ns < 1_000_000_000);
    try std.testing.expect(second.duration_ns >= 250_000_000 and second.duration_ns < 1_000_000_000);
    const first_end: i64 = @intCast(first.start_unix_ns + first.duration_ns);
    const gap: i64 = @as(i64, @intCast(second.start_unix_ns)) - first_end;
    try std.testing.expect(@abs(gap) < 5_000_000); // within 5 ms
    try std.testing.expect(first.start_unix_ns > 1_577_836_800 * 1_000_000_000);
    try std.testing.expectEqual(@as(u32, 99), first.cpu_sample_hz);

    // The unit the backend will rely on: samples / hz is CPU time, and one busy thread
    // cannot use much more than the wall time it ran, or much less than half of it.
    const cpu_ns = first.cpu.?.samples * 1_000_000_000 / first.cpu_sample_hz;
    try std.testing.expect(cpu_ns >= first.duration_ns / 2 and cpu_ns <= first.duration_ns + first.duration_ns / 2);
    // 300 ms at 99 Hz is about 30 samples per window.
    try std.testing.expect(first.cpu.?.samples >= 5);
    try std.testing.expectEqual(sys.currentPid(), first.pid);
    try std.testing.expect(locate(first.regions, @intFromPtr(&burn)) != null);

    // Nothing may be counted without its frames, and no ring record may be rejected.
    try std.testing.expect(first.cpu.?.lost.held_back == 0);
    try std.testing.expect(second.cpu.?.lost.held_back == 0);
    try std.testing.expect(first.cpu.?.lost.bad_records == 0);
    try std.testing.expect(second.cpu.?.lost.bad_records == 0);

    // How many of the user frames can be traced back to a file?
    var total: usize = 0;
    var resolved: usize = 0;
    for (first.cpu.?.stacks) |stack| {
        for (stack.user) |addr| {
            total += 1;
            if (locate(first.regions, addr) != null) resolved += 1;
        }
    }
    std.debug.print("user frames: {d}, resolved to a file or [vdso]: {d}\n", .{ total, resolved });
    try std.testing.expect(total == 0 or resolved > 0);

    std.debug.print("session: {d} and {d} samples in windows of {d} and {d} ms\n", .{
        first.cpu.?.samples,           second.cpu.?.samples,
        first.duration_ns / 1_000_000, second.duration_ns / 1_000_000,
    });

    // With the tables loaded a stack has its callers, not just the instruction that was running.
    try std.testing.expect(first.cpu.?.stacks.len > 0);

    var deepest: usize = 0;
    for (first.cpu.?.stacks, 0..) |stack, i| {
        if (stack.user.len > deepest) deepest = stack.user.len;
        if (i < 8) std.debug.print("stack {d}: samples={d} user={d} kernel={d} stop={any}\n", .{
            i, stack.samples, stack.user.len, stack.kernel.len, stack.stop,
        });
    }
    std.debug.print("session: deepest user stack has {d} frames\n", .{deepest});
    try std.testing.expect(deepest >= 3);
}
