//! The processes layer.

const std = @import("std");
const timer = @import("../os/os.zig").timer;
const assert = std.debug.assert;

const Proc = @import("proc.zig").Proc;
const Entry = @import("proc.zig").Entry;
const Stat = @import("stat.zig").Stat;
const MachineStat = @import("machine.zig").Machine;

const protocol = @import("shared").protocol;
pub const ProcessInfo = protocol.ProcessInfo;
pub const Frame = protocol.ProcessFrame;
pub const Machine = protocol.Machine;
pub const MachineCpu = protocol.MachineCpu;

pub const Processes = struct {
    procs: [2]Proc = .{ .{}, .{} },
    now: usize = 0,
    previous_ns: ?u64 = null,
    ticks_per_s: u64,
    boot_unix_ns: u64,
    infos: std.ArrayList(ProcessInfo) = .empty,

    pub fn init() Processes {
        const ticks = std.c.getauxval(std.elf.AT_CLKTCK);
        assert(ticks > 0);
        const boot_unix_ns = timer.realtime_ns() - timer.boottime_ns();
        return .{ .ticks_per_s = ticks, .boot_unix_ns = boot_unix_ns };
    }

    pub fn deinit(processes: *Processes, gpa: std.mem.Allocator) void {
        for (&processes.procs) |*proc| proc.deinit(gpa);
        processes.infos.deinit(gpa);
        processes.* = undefined;
    }

    pub fn take(processes: *Processes, gpa: std.mem.Allocator) !Frame {
        const now_ns = timer.monotonic_ns();
        const now = &processes.procs[processes.now];
        const before = &processes.procs[1 - processes.now];
        try now.read(gpa);
        const interval_ns: u64 = if (processes.previous_ns) |previous| now_ns - previous else 0;
        const first = processes.previous_ns == null;
        const machine = Machine{
            .cpus = now.machine.cpus,
            .cpu = if (first) null else machine_cpu(&before.machine, &now.machine),
        };

        processes.infos.clearRetainingCapacity();
        var entries = now.entries.valueIterator();
        while (entries.next()) |entry| {
            try processes.infos.append(gpa, .{
                .pid = entry.stat.pid,
                .name = entry.stat.name(),
                .user = entry.user,
                .threads = entry.status.threads,
                .command = entry.cmdline.text(),
                .cpu_percent = processes.cpu_of(before, entry),
                .memory_bytes = entry.status.rss_kb * 1024,
                .started_unix_ns = processes.started_of(&entry.stat),
            });
        }

        processes.previous_ns = now_ns;
        processes.now = 1 - processes.now;
        return .{
            .unix_ns = timer.realtime_ns(),
            .interval_ns = interval_ns,
            .processes = processes.infos.items,
            .machine = machine,
        };
    }

    fn cpu_of(processes: *const Processes, before: *const Proc, entry: *const Entry) ?f32 {
        const old = before.same(&entry.stat) orelse return null;
        const interval_ns = entry.read_ns - old.read_ns;
        if (interval_ns == 0) return null;
        const ticks_per_s = processes.ticks_per_s;
        return cpu_percent(old.stat.cpu_ticks, entry.stat.cpu_ticks, interval_ns, ticks_per_s);
    }

    fn started_of(processes: *const Processes, stat: *const Stat) u64 {
        return started_unix_ns(processes.boot_unix_ns, stat.start_ticks, processes.ticks_per_s);
    }

    fn cpu_percent(ticks_before: u64, ticks_now: u64, interval_ns: u64, ticks_per_s: u64) f32 {
        assert(interval_ns > 0);
        assert(ticks_per_s > 0);
        assert(ticks_now >= ticks_before);
        const used_s = @as(f64, @floatFromInt(ticks_now - ticks_before)) /
            @as(f64, @floatFromInt(ticks_per_s));
        const interval_s = @as(f64, @floatFromInt(interval_ns)) / std.time.ns_per_s;
        return @floatCast(used_s / interval_s * 100);
    }

    fn machine_cpu(before: *const MachineStat, now: *const MachineStat) ?MachineCpu {
        const delta = now.since(before);
        const total = delta.total();
        if (total == 0) return null;
        const idle = delta.idle + delta.iowait;
        assert(idle <= total);
        return .{
            .busy_percent = share(total - idle, total),
            .user_percent = share(delta.user + delta.nice, total),
            .system_percent = share(delta.system, total),
            .iowait_percent = share(delta.iowait, total),
            .irq_percent = share(delta.irq + delta.softirq, total),
            .steal_percent = share(delta.steal, total),
        };
    }

    fn share(ticks: u64, total: u64) f32 {
        assert(total > 0);
        assert(ticks <= total);
        const ratio = @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(total));
        return @floatCast(ratio * 100);
    }

    fn started_unix_ns(boot_unix_ns: u64, start_ticks: u64, ticks_per_s: u64) u64 {
        assert(ticks_per_s > 0);
        return boot_unix_ns + start_ticks * std.time.ns_per_s / ticks_per_s;
    }
};
const testing = std.testing;

test {
    _ = @import("proc.zig");
    _ = @import("machine.zig");
    _ = @import("stat.zig");
    _ = @import("statm.zig");
    _ = @import("status.zig");
    _ = @import("users.zig");
    _ = @import("cmdline.zig");
}

test "cpu_percent is per core" {
    const second = std.time.ns_per_s;
    try testing.expectApproxEqAbs(@as(f32, 50), Processes.cpu_percent(100, 150, second, 100), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 200), Processes.cpu_percent(0, 200, second, 100), 0.01);
    try testing.expectEqual(@as(f32, 0), Processes.cpu_percent(7, 7, second, 100));
}

test "machine_cpu: each state a share of every CPU, idle and iowait not busy" {
    const before = MachineStat{ .cpus = 2 };
    const now = MachineStat{
        .cpus = 2,
        .user = 60,
        .nice = 20,
        .system = 30,
        .idle = 60,
        .iowait = 10,
        .irq = 5,
        .softirq = 5,
        .steal = 10,
    };
    const cpu = Processes.machine_cpu(&before, &now).?;
    try testing.expectApproxEqAbs(@as(f32, 65), cpu.busy_percent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), cpu.user_percent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 15), cpu.system_percent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 5), cpu.iowait_percent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 5), cpu.irq_percent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 5), cpu.steal_percent, 0.01);
    try testing.expectEqual(@as(?MachineCpu, null), Processes.machine_cpu(&now, &now));
}

test "started_unix_ns counts ticks from the boot" {
    try testing.expectEqual(
        @as(u64, 1000 + 2_500_000_000),
        Processes.started_unix_ns(1000, 250, 100),
    );
}
