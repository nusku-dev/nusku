const std = @import("std");
const timer = @import("../os/timer.zig");
const assert = std.debug.assert;

const Proc = @import("proc.zig").Proc;
const Stat = @import("stat.zig").Stat;

pub const ProcessInfo = struct {
    pid: u32,
    name: []const u8,
    user: []const u8,
    command: []const u8,
    threads: u32,
    /// Null on the first look: CPU is measured against the look before.
    cpu_percent: ?f32,
    /// Resident memory (RSS).
    memory_bytes: u64,
    started_unix_ns: u64,
};

/// One look at the machine: every process at once.
pub const Frame = struct {
    /// When the look was taken (CLOCK_REALTIME).
    unix_ns: u64,
    /// Since the look before: what `cpu_percent` is measured over. 0 on the first look.
    interval_ns: u64,
    processes: []const ProcessInfo,
};

/// The look now and the look before, swapped each look, and the frame built from them.
pub const Looks = struct {
    procs: [2]Proc = .{ .{}, .{} },
    /// Which of `procs` the next read fills.
    now: usize = 0,
    /// When the look before was taken (monotonic), or null before the first.
    previous_ns: ?u64 = null,
    /// Clock ticks per second, the unit of CPU time in /proc. 100 on every Linux today, but
    /// the kernel says it in the auxiliary vector, so it is read, not assumed.
    ticks_per_s: u64,
    /// When the machine booted, in Unix ns: /proc counts start times from it.
    boot_unix_ns: u64,
    infos: std.ArrayList(ProcessInfo) = .empty,

    pub fn init() Looks {
        const ticks = std.c.getauxval(std.elf.AT_CLKTCK);
        assert(ticks > 0);
        // Read back to back: wall time now minus time since boot is when it booted.
        const boot_unix_ns = timer.realtime_ns() - timer.boottime_ns();
        return .{ .ticks_per_s = ticks, .boot_unix_ns = boot_unix_ns };
    }

    pub fn deinit(looks: *Looks, gpa: std.mem.Allocator) void {
        for (&looks.procs) |*proc| proc.deinit(gpa);
        looks.infos.deinit(gpa);
        looks.* = undefined;
    }

    // Every process now. The frame points into `looks`: good until the next `take`.
    pub fn take(looks: *Looks, gpa: std.mem.Allocator) !Frame {
        const now_ns = timer.monotonic_ns();
        const now = &looks.procs[looks.now];
        const before = &looks.procs[1 - looks.now];
        try now.read(gpa);
        const interval_ns: u64 = if (looks.previous_ns) |previous| now_ns - previous else 0;

        looks.infos.clearRetainingCapacity();
        var entries = now.entries.valueIterator();
        while (entries.next()) |entry| {
            try looks.infos.append(gpa, .{
                .pid = entry.stat.pid,
                .name = entry.stat.name(),
                .user = entry.user,
                .threads = entry.status.threads,
                .command = entry.cmdline.text(),
                .cpu_percent = looks.cpu_of(before, &entry.stat, interval_ns),
                .memory_bytes = entry.status.rss_kb * 1024,
                .started_unix_ns = looks.started_of(&entry.stat),
            });
        }

        looks.previous_ns = now_ns;
        looks.now = 1 - looks.now;
        return .{
            .unix_ns = timer.realtime_ns(),
            .interval_ns = interval_ns,
            .processes = looks.infos.items,
        };
    }

    /// Null on the first look, and for a process that started since the look before.
    fn cpu_of(looks: *const Looks, before: *const Proc, stat: *const Stat, interval_ns: u64) ?f32 {
        if (interval_ns == 0) return null;
        const old = before.same(stat) orelse return null;
        return cpu_percent(old.stat.cpu_ticks, stat.cpu_ticks, interval_ns, looks.ticks_per_s);
    }

    /// When the process started, in Unix ns.
    fn started_of(looks: *const Looks, stat: *const Stat) u64 {
        return started_unix_ns(looks.boot_unix_ns, stat.start_ticks, looks.ticks_per_s);
    }

    /// CPU use between two looks, per core: a process busy on 2 cores shows 200, as in `top`.
    fn cpu_percent(ticks_before: u64, ticks_now: u64, interval_ns: u64, ticks_per_s: u64) f32 {
        assert(interval_ns > 0);
        assert(ticks_per_s > 0);
        // The kernel never takes CPU time back from a process: `same` made sure it is one.
        assert(ticks_now >= ticks_before);
        const used_s = @as(f64, @floatFromInt(ticks_now - ticks_before)) /
            @as(f64, @floatFromInt(ticks_per_s));
        const interval_s = @as(f64, @floatFromInt(interval_ns)) / std.time.ns_per_s;
        return @floatCast(used_s / interval_s * 100);
    }

    /// Start ticks since boot to Unix ns. Pure, so it is tested without a process.
    fn started_unix_ns(boot_unix_ns: u64, start_ticks: u64, ticks_per_s: u64) u64 {
        assert(ticks_per_s > 0);
        return boot_unix_ns + start_ticks * std.time.ns_per_s / ticks_per_s;
    }
};
const testing = std.testing;

test "cpu_percent is per core" {
    const second = std.time.ns_per_s;
    try testing.expectApproxEqAbs(@as(f32, 50), Looks.cpu_percent(100, 150, second, 100), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), Looks.cpu_percent(0, 200, second, 100), 0.01);
    try testing.expectEqual(@as(f32, 0), Looks.cpu_percent(7, 7, second, 100));
}

test "started_unix_ns counts ticks from the boot" {
    // 250 ticks at 100 per second: 2.5 s after the boot.
    try testing.expectEqual(
        @as(u64, 1000 + 2_500_000_000),
        Looks.started_unix_ns(1000, 250, 100),
    );
}
