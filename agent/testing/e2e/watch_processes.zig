//! End to end: watching the processes of the machine sees children whose behavior is known.
//!
//! Four children, each named with prctl so the frames can tell them apart:
//!   nusku-burn    keeps one core busy: about 100% CPU
//!   nusku-sleep   sleeps: about 0% CPU
//!   nusku-memory  writes 64 MiB, then sleeps: at least 64 MiB resident
//!   nusku-short   killed and reaped after the second frame: in no frame after it
//! No root needed: a user may read every file the watch reads for their own processes.

const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const watch = @import("../../processes/process.zig");
const child_process = @import("../process.zig");
const anonymous_memory = @import("../../os/anonymous_memory.zig");
const timer = @import("../../os/timer.zig");
const ProcessInfo = @import("../../processes/process.zig").ProcessInfo;
const processes = @import("../../processes.zig");

const watch_processes = processes.watch_processes;
const StopReason = processes.StopReason;

const Frame = watch.Frame;

const Role = enum { burn, sleep, memory, short };

const memory_bytes = 64 * 1024 * 1024;
/// Longer than the watch: the test kills every child itself.
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

    // The child. The parent may have threads: only system calls from here, no allocator.
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr(role_name(role).ptr), 0, 0, 0);
    switch (role) {
        .burn => child_process.cpu_burn(child_life_ms),
        .sleep, .short => timer.sleep_ms(child_life_ms),
        .memory => {
            const bytes = anonymous_memory.reserve(memory_bytes) catch std.c._exit(1);
            @memset(bytes, 0xaa); // Written, so every page is resident.
            timer.sleep_ms(child_life_ms);
        },
    }
    std.c._exit(0);
}

/// libc's own reading of /etc/passwd: an answer that does not come from our `Users`.
/// Only the first field of `struct passwd` is used, so only it is declared.
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
    /// Each child as the last frame it was in showed it. `name`, `user` and `command` are
    /// cleared: they point into the frame, which is gone after the callback. // CHANGED
    last: std.EnumArray(Role, ?ProcessInfo) = .initFill(null),
    named: std.EnumArray(Role, bool) = .initFill(false),
    /// Every child, in every frame, had `expected_user`.
    users_ok: bool = true,
    /// Every child, in every frame, had one thread: fork copies only the calling one. // NEW
    threads_ok: bool = true, // NEW
    /// Every child, in every frame, had the test binary's command line: prctl changes the
    /// name, not the command. // NEW
    commands_ok: bool = true, // NEW
    short_reaped: bool = false,
    short_seen_after_reap: bool = false,

    /// The burn child's command line, copied while its frame was valid, for the summary.
    command_buffer: [256]u8 = undefined,
    command_len: usize = 0,

    fn on_frame(seen: *Seen, frame: *const Frame) void {
        seen.frames += 1;

        // The test's own command line, from the same frame: what every child inherited. // NEW
        const own_pid: u32 = @intCast(linux.getpid()); // NEW
        const own_command = for (frame.processes) |info| { // NEW
            if (info.pid == own_pid) break info.command;
        } else "";

        for (frame.processes) |info| {
            for (std.enums.values(Role)) |role| {
                if (info.pid != seen.pids.get(role)) continue;
                if (role == .short and seen.short_reaped) seen.short_seen_after_reap = true;
                if (std.mem.eql(u8, info.name, role_name(role))) seen.named.set(role, true);
                if (!std.mem.eql(u8, info.user, seen.expected_user)) seen.users_ok = false;
                if (info.threads != 1) seen.threads_ok = false; // NEW
                if (info.command.len == 0 or !std.mem.eql(u8, info.command, own_command)) { // NEW
                    seen.commands_ok = false;
                }
                if (role == .burn) {
                    seen.command_len = @min(info.command.len, seen.command_buffer.len);
                    @memcpy(
                        seen.command_buffer[0..seen.command_len],
                        info.command[0..seen.command_len],
                    );
                }
                var copy = info;
                copy.name = "";
                copy.user = "";
                copy.command = ""; // NEW
                seen.last.set(role, copy);
            }
        }
        if (seen.frames == 2) {
            child_process.child_reap(seen.pids.get(.short));
            seen.short_reaped = true;
        }
    }
};

test "watching sees what known children do: CPU, memory, names, users, threads, commands, starts, and one that ends" { // CHANGED
    var seen = Seen{ .pids = .initUndefined(), .expected_user = user_expected() };
    var spawned: std.EnumSet(Role) = .initEmpty();
    // Reaped once only: after the wait, the pid may already be another process's.
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

    const reason = try watch_processes(testing.allocator, .{
        .interval_ms = 250,
        .duration_s = 2,
    }, &seen, Seen.on_frame);
    try testing.expectEqual(StopReason.duration, reason);
    try testing.expect(seen.frames >= 4);

    const burn = seen.last.get(.burn).?;
    const sleep = seen.last.get(.sleep).?;
    const memory = seen.last.get(.memory).?;
    // std.debug.print(
    //     "watch e2e: {d} frames, user {s}; burn {d:.1}%, sleep {d:.1}%, memory {d} MiB, " ++
    //         "threads {d}\n  command: {s}\n",
    //     .{
    //         seen.frames,
    //         seen.expected_user,
    //         burn.cpu_percent.?,
    //         sleep.cpu_percent.?,
    //         memory.memory_bytes >> 20,
    //         burn.threads,
    //         seen.command_buffer[0..seen.command_len],
    //     },
    // );

    // Names: each child is found under the name it gave itself.
    for (std.enums.values(Role)) |role| try testing.expect(seen.named.get(role));

    // Users: the children run as whoever runs the test, and libc agrees on that name.
    try testing.expect(!std.mem.eql(u8, seen.expected_user, "unknown"));
    try testing.expect(seen.users_ok);

    // Threads: a forked child has one, the one that called fork. // NEW
    try testing.expect(seen.threads_ok); // NEW

    // Commands: a forked child keeps the command line of the test binary. // NEW
    try testing.expect(seen.commands_ok); // NEW

    // CPU: one busy core is about 100%. Loose bounds: a loaded machine gives it less.
    try testing.expect(burn.cpu_percent.? > 50 and burn.cpu_percent.? < 130);
    try testing.expect(sleep.cpu_percent.? < 5);

    // Memory: the 64 MiB written are resident, and the sleeper has far less.
    try testing.expect(memory.memory_bytes >= memory_bytes);
    try testing.expect(sleep.memory_bytes < memory_bytes);

    // Starts: each child started when it was forked. Ticks are 10 ms, so allow a little.
    for (std.enums.values(Role)) |role| {
        const started = seen.last.get(role).?.started_unix_ns;
        const off_ns = if (started > forked_unix_ns)
            started - forked_unix_ns
        else
            forked_unix_ns - started;
        try testing.expect(off_ns < std.time.ns_per_s);
    }

    // An ended process: seen while it ran, never after it was reaped.
    try testing.expect(seen.last.get(.short) != null);
    try testing.expect(!seen.short_seen_after_reap);
}
