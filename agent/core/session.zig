const std = @import("std");
const ebpf = @import("ebpf");
const Metric = @import("config.zig").Metric;
const sys = @import("sys.zig");
const times = @import("timer.zig");
const procmaps = @import("procmaps.zig");
const kernel = @import("kernel.zig");
const unwind = @import("unwind");
const tables = @import("tables.zig");
const oncpu = ebpf.oncpu;

pub const CpuWindow = oncpu.Window;
pub const StackSample = oncpu.StackSample;
pub const StackLoss = oncpu.StackLoss;

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
    regions: []const procmaps.Region = &.{},
    kernel: kernel.Identity = .{},
    cpu: ?CpuWindow = null,
};

pub const Session = struct {
    pid: u32,
    allocator: std.mem.Allocator,
    /// The unwind tables of every binary the target has mapped so far.
    registry: unwind.registry.Registry,
    /// The BPF maps that the tables and the target's mapping list are written to.
    bpf_tables: ebpf.tablemaps.TableMaps,
    /// The mapping list of the target as last written to the maps. On the heap, it is large.
    entry: *tables.ProcessEntry,
    /// Times the tables could not be refreshed. Unwinding keeps using the older ones.
    table_failures: u32 = 0,
    cpu: ?oncpu.OnCpu,
    maps: procmaps.ProcessMaps,
    /// Owns the strings inside `kernel`.
    kernel_arena: std.heap.ArenaAllocator,
    kernel: kernel.Identity,
    /// Where the current window began, on both clocks.
    window_start_mono_ns: u64,
    window_start_unix_ns: u64,

    /// Starts sampling `pid` with one collector per requested metric. Needs root, or CAP_BPF and
    /// CAP_PERFMON. If this fails, nothing stays loaded and nothing stays attached.
    pub fn init(allocator: std.mem.Allocator, metrics: std.EnumSet(Metric), pid: u32) !Session {
        if (!sys.isValidPid(pid)) return error.InvalidPid;
        if (metrics.count() == 0) return error.NoMetrics;
        var requested = metrics.iterator();
        while (requested.next()) |metric| switch (metric) {
            .cpu => {},
            else => return error.MetricNotImplemented,
        };

        var maps = procmaps.ProcessMaps.init(allocator, pid);
        errdefer maps.deinit();
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const regions = try maps.read(scratch.allocator());
        if (maps.table.len == 0) return error.ProcessNotFound;

        // The kernel's identity cannot change while we run, so read it once.
        var kernel_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer kernel_arena.deinit();
        const kernel_info = try kernel.read(kernel_arena.allocator());

        // Load every collector before attaching any, so a failure in one never leaves another
        // one sampling.
        var cpu: ?oncpu.OnCpu = null;
        errdefer if (cpu) |*c| c.deinit();
        if (metrics.contains(.cpu)) cpu = try oncpu.OnCpu.init(allocator);
        // The tables go in before sampling starts, so even the first sample can be unwound.
        var registry = unwind.registry.Registry.init(allocator, 262_144, 256);
        errdefer registry.deinit();
        var bpf_tables = try cpu.?.tables();
        errdefer bpf_tables.deinit();
        const entry = try allocator.create(tables.ProcessEntry);
        errdefer allocator.destroy(entry);
        {
            const built = try tables.build(allocator, &registry, pid, regions);
            try bpf_tables.writeModulesFrom(registry.set, 0);
            try bpf_tables.writeProcess(pid, built.entry);
            entry.* = built.entry;
        }
        // The first window begins just before the attach, so it is never shorter than the sampling.
        const began_mono = times.monotonicNs();
        const began_unix = times.realtimeNs();
        if (cpu) |*c| try c.start(pid, sample_hz);

        return .{
            .allocator = allocator,
            .registry = registry,
            .bpf_tables = bpf_tables,
            .entry = entry,
            .pid = pid,
            .cpu = cpu,
            .maps = maps,
            .kernel_arena = kernel_arena,
            .kernel = kernel_info,
            .window_start_mono_ns = began_mono,
            .window_start_unix_ns = began_unix,
        };
    }

    /// What was sampled since the previous report (or since `init`). Everything inside the
    /// result lives in `arena`; release it by resetting or deinitializing the arena.
    pub fn report(self: *Session, arena: std.mem.Allocator) !Report {
        // The boundary between windows. Read before collecting, so it is not later than the data.
        const now_mono = times.monotonicNs();
        const now_unix = times.realtimeNs();

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
        // After collecting: a library loaded before the last sample is then in the table.
        result.regions = try self.maps.read(arena);
        // A failure here must not lose the window we just collected: the older tables stay in use.
        self.refreshTables(result.regions) catch {
            self.table_failures += 1;
        };

        // Only now does the next window begin. If anything above failed, the next report
        // covers the whole span, so nothing is lost.
        self.window_start_mono_ns = now_mono;
        self.window_start_unix_ns = now_unix;
        return result;
    }

    /// Loads the tables of binaries the target mapped since the last call, and rewrites its
    /// mapping list when it changed. Binaries go in first, so the list never points at a missing one.
    fn refreshTables(self: *Session, regions: []const procmaps.Region) !void {
        const before = self.registry.set.modules.items.len;
        const built = try tables.build(self.allocator, &self.registry, self.pid, regions);
        try self.bpf_tables.writeModulesFrom(self.registry.set, before);
        if (!std.mem.eql(u8, std.mem.asBytes(&built.entry), std.mem.asBytes(self.entry))) {
            try self.bpf_tables.writeProcess(self.pid, built.entry);
            self.entry.* = built.entry;
        }
    }

    /// Stops sampling and releases everything. Never fails.
    pub fn deinit(self: *Session) void {
        self.bpf_tables.deinit();
        self.registry.deinit();
        if (self.cpu) |*cpu| cpu.deinit();
        self.allocator.destroy(self.entry);
        self.maps.deinit();
        self.kernel_arena.deinit();
        self.* = undefined;
    }
};

const Set = std.EnumSet(Metric);

fn burn(ms: u64) void {
    const until = times.nowMs() + ms;
    var x: u64 = 0;
    while (times.nowMs() < until) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

test "init rejects bad input before loading anything" {
    const a = std.testing.allocator;
    const me = sys.currentPid();
    try std.testing.expectError(error.InvalidPid, Session.init(a, Set.initOne(.cpu), 0));
    try std.testing.expectError(error.NoMetrics, Session.init(a, Set.initEmpty(), me));
    try std.testing.expectError(error.MetricNotImplemented, Session.init(a, Set.initOne(.mem), me));
    try std.testing.expectError(error.MetricNotImplemented, Session.init(a, Set.initMany(&.{ .cpu, .io }), me));
    try std.testing.expectError(error.ProcessNotFound, Session.init(a, Set.initOne(.cpu), std.math.maxInt(i32)));
}

test "session samples this process and reports one window per call (needs root, skipped otherwise)" {
    var session = Session.init(std.testing.allocator, Set.initOne(.cpu), sys.currentPid()) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
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
    try std.testing.expect(procmaps.locate(first.regions, @intFromPtr(&burn)) != null);

    // How many of the user frames can be traced back to a file?
    var total: usize = 0;
    var resolved: usize = 0;
    for (first.cpu.?.stacks) |stack| {
        for (stack.user) |addr| {
            total += 1;
            if (procmaps.locate(first.regions, addr) != null) resolved += 1;
        }
    }
    std.debug.print("user frames: {d}, resolved to a file or [vdso]: {d}\n", .{ total, resolved });
    try std.testing.expect(total == 0 or resolved > 0);

    std.debug.print("session: {d} and {d} samples in windows of {d} and {d} ms\n", .{
        first.cpu.?.samples,           second.cpu.?.samples,
        first.duration_ns / 1_000_000, second.duration_ns / 1_000_000,
    });

    // With the tables loaded a stack has its callers, not just the instruction that was running.
    const hottest = first.cpu.?.stacks[0];
    std.debug.print("session: the hottest stack has {d} user frames and {d} samples\n", .{ hottest.user.len, hottest.samples });
    try std.testing.expect(hottest.user.len >= 3);
}
