//! End to end: the watch sees what four children.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const process_file = @import("../../processes/processes.zig");
const child_process = @import("../process.zig");
const anonymous_memory = @import("../../os/os.zig").anonymous_memory;
const timer = @import("../../os/os.zig").timer;
const ProcessInfo = @import("../../processes/processes.zig").ProcessInfo;
const Watch = @import("../../watch.zig").Watch;
const protocol = @import("shared").protocol;

const Frame = process_file.Frame;

const Role = enum { burn, sleep, memory, short };

const memory_bytes = 64 * 1024 * 1024;
const child_life_ms = 10_000;

fn role_name(role: Role) [:0]const u8 {
    return switch (role) {
        .burn => "nusku-burn",
        .sleep => "nusku-sleep",
        .memory => "nusku-memory",
        .short => "nusku-short",
    };
}

fn child_spawn(role: Role) !u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid != 0) return @intCast(pid);

    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(role_name(role).ptr), 0, 0, 0);
    switch (role) {
        .burn => child_process.cpu_burn(child_life_ms),
        .sleep, .short => timer.sleep_ms(child_life_ms),
        .memory => {
            const bytes = anonymous_memory.reserve(memory_bytes) catch std.c._exit(1);
            @memset(bytes, 0xaa);
            timer.sleep_ms(child_life_ms);
        },
    }
    std.c._exit(0);
}

const Passwd = extern struct { pw_name: [*:0]const u8 };
extern "c" fn getpwuid(uid: u32) ?*const Passwd;

fn user_expected() []const u8 {
    const entry = getpwuid(linux.geteuid()) orelse return "unknown";
    return std.mem.span(entry.pw_name);
}

const Seen = struct {
    pids: std.EnumArray(Role, u32),
    expected_user: []const u8,
    frames: u32 = 0,
    last: std.EnumArray(Role, ?ProcessInfo) = .initFill(null),
    named: std.EnumArray(Role, bool) = .initFill(false),
    users_ok: bool = true,
    threads_ok: bool = true,
    commands_ok: bool = true,
    short_reaped: bool = false,
    short_seen_after_reap: bool = false,
    machine_first: ?protocol.Machine = null,
    machine_last: protocol.Machine = .{},
    processes_cpu_percent: f32 = 0,

    fn on_frame(seen: *Seen, frame: *const Frame) void {
        seen.frames += 1;
        if (seen.machine_first == null) seen.machine_first = frame.machine;
        seen.machine_last = frame.machine;
        seen.processes_cpu_percent = 0;
        for (frame.processes) |info| seen.processes_cpu_percent += info.cpu_percent orelse 0;

        const own_pid: u32 = @intCast(linux.getpid());
        const own_command = for (frame.processes) |info| {
            if (info.pid == own_pid) break info.command;
        } else "";

        for (frame.processes) |info| {
            for (std.enums.values(Role)) |role| {
                if (info.pid != seen.pids.get(role)) continue;
                if (role == .short and seen.short_reaped) seen.short_seen_after_reap = true;
                if (std.mem.eql(u8, info.name, role_name(role))) seen.named.set(role, true);
                if (!std.mem.eql(u8, info.user, seen.expected_user)) seen.users_ok = false;
                if (info.threads != 1) seen.threads_ok = false;
                if (info.command.len == 0 or !std.mem.eql(u8, info.command, own_command)) {
                    seen.commands_ok = false;
                }
                var copy = info;
                copy.name = "";
                copy.user = "";
                copy.command = "";
                seen.last.set(role, copy);
            }
        }
        if (seen.frames == 2) {
            child_process.child_reap(seen.pids.get(.short));
            seen.short_reaped = true;
        }
    }
};

test "the watch sees what known children do, and one that ends" {
    var seen = Seen{ .pids = .initUndefined(), .expected_user = user_expected() };
    var spawned: std.EnumSet(Role) = .initEmpty();
    defer for (std.enums.values(Role)) |role| {
        if (!spawned.contains(role)) continue;
        if (role == .short and seen.short_reaped) continue;
        child_process.child_reap(seen.pids.get(role));
    };

    const forked_unix_ns = timer.realtime_ns();
    for (std.enums.values(Role)) |role| {
        seen.pids.set(role, try child_spawn(role));
        spawned.insert(role);
    }

    var watch = try Watch.init(testing.allocator, .{ .interval_ms = 250, .duration_s = 2 });
    defer watch.deinit();
    var stopped: ?protocol.WatchStop = null;
    while (try watch.next()) |event| switch (event) {
        .frame => |frame| seen.on_frame(frame),
        .stopped => |reason| stopped = reason,
    };
    try testing.expectEqual(@as(?protocol.WatchStop, .duration), stopped);
    try testing.expect(seen.frames >= 4);

    const burn = seen.last.get(.burn).?;
    const sleep = seen.last.get(.sleep).?;
    const memory = seen.last.get(.memory).?;
    for (std.enums.values(Role)) |role| try testing.expect(seen.named.get(role));
    try testing.expect(!std.mem.eql(u8, seen.expected_user, "unknown"));
    try testing.expect(seen.users_ok);
    try testing.expect(seen.threads_ok);
    try testing.expect(seen.commands_ok);

    std.debug.print("watch e2e: {d} frames, burn {d:.1}%, sleep {d:.1}%\n", .{
        seen.frames, burn.cpu_percent.?, sleep.cpu_percent.?,
    });
    try testing.expect(burn.cpu_percent.? > 50 and burn.cpu_percent.? < 130);
    try testing.expect(sleep.cpu_percent.? < 5);

    try testing.expect(memory.memory_bytes >= memory_bytes);
    try testing.expect(sleep.memory_bytes < memory_bytes);

    for (std.enums.values(Role)) |role| {
        const started = seen.last.get(role).?.started_unix_ns;
        const off_ns = if (started > forked_unix_ns)
            started - forked_unix_ns
        else
            forked_unix_ns - started;
        try testing.expect(off_ns < std.time.ns_per_s);
    }

    try testing.expect(seen.last.get(.short) != null);
    try testing.expect(!seen.short_seen_after_reap);

    try machine_check(&seen, burn.cpu_percent.?);
}

fn machine_check(seen: *const Seen, burn_cpu_percent: f32) !void {
    const first = seen.machine_first.?;
    const machine = seen.machine_last;
    try testing.expectEqual(@as(?protocol.MachineCpu, null), first.cpu);
    try testing.expectEqual(try std.Thread.getCpuCount(), machine.cpus);
    const cpu = machine.cpu.?;
    const cpus: f32 = @floatFromInt(machine.cpus);
    std.debug.print("watch e2e: machine {d:.1}% of {d} CPUs ({d:.0}% of one), " ++
        "processes sum {d:.0}%\n", .{
        cpu.busy_percent, machine.cpus, cpu.busy_percent * cpus, seen.processes_cpu_percent,
    });

    const states = cpu.user_percent + cpu.system_percent + cpu.irq_percent + cpu.steal_percent;
    try testing.expectApproxEqAbs(cpu.busy_percent, states, 0.1);
    try testing.expect(cpu.busy_percent <= 100 and cpu.iowait_percent >= 0);
    try testing.expect(cpu.busy_percent * cpus >= burn_cpu_percent - 10);
}
