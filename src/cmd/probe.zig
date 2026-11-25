//! `nusku probe`: count and time every call of one function in a running process.

const std = @import("std");
const cli = @import("cli");
const log = @import("log");
const client = @import("client");
const flags = @import("flags.zig");
const term = @import("../term/term.zig");
const view = @import("../view/view.zig").probe;

pub const cmd: cli.Command = .{
    .name = "probe",
    .short = "Count and time every call of one function in a running process",
    .long =
    \\Puts a probe on the entry and the return of a function, and times every call of
    \\it: how many calls, how many a second, how long each took (mean, p50, p90, p99,
    \\slowest), and a histogram of the times. Nothing in the program changes, and it
    \\need not be rebuilt.
    \\
    \\The function is named as `nusku prof` names it. --module picks the file when
    \\the name is in more than one (by path or file name). An inlined function has no
    \\call to probe, and Go programs are refused: their runtime moves stacks, which
    \\breaks return probes.
    \\
    \\Each call costs a few microseconds of probe: fine for a function called a few
    \\thousand times a second, too much for one called millions of times.
    \\
    \\Needs root or CAP_SYS_ADMIN: the kernel opens uprobes to nothing less.
    ,
    .flags = &.{
        .{ .name = "pid", .short = 'p', .kind = .int, .help = "The process to probe" },
        .{ .name = "function", .short = 'f', .kind = .string, .help = "The function to time" },
        .{
            .name = "module",
            .short = 'm',
            .kind = .string,
            .help = "The file the function is in, by path or file name",
        },
        .{
            .name = "interval",
            .kind = .int,
            .default = "1000",
            .help = "Milliseconds between two looks at the counts",
        },
        .{ .name = "duration", .kind = .int, .default = "0", .help = "Seconds; 0 until Ctrl-C" },
        .{ .name = "no-live", .kind = .bool, .help = "Print only the final report" },
        flags.color,
    },
    .run = run,
};

const user: client.UserId = 1;

var interrupted = std.atomic.Value(bool).init(false);

fn on_interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Settings = struct {
    options: client.ProbeOptions,
    live: bool,
    color: bool,
};

fn run(ctx: *cli.Context) anyerror!void {
    try flags.log_apply(ctx);
    const settings = try settings_read(ctx);
    if (!ctx.isSet("log-level") and !ctx.getBool("verbose")) {
        if (log.getDefault()) |logger| logger.setLevel(.warn);
    }
    const action = std.posix.Sigaction{
        .handler = .{ .handler = on_interrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);

    const session = try std.heap.smp_allocator.create(client.Session);
    defer std.heap.smp_allocator.destroy(session);
    session.init(std.heap.smp_allocator, .{}) catch |err| {
        return ctx.fail("cannot start a session: {t}", .{err});
    };
    defer session.deinit();
    const job = session.probe_start(settings.options, user) catch |err| {
        return ctx.fail("cannot probe {s}: {s}", .{ settings.options.function, hint(err) });
    };
    try watch(ctx, session, job, settings);
}

fn watch(ctx: *cli.Context, session: *client.Session, job: u64, settings: Settings) !void {
    const w = ctx.stdout;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var lines: usize = 0;
    if (settings.live) try w.writeAll(term.cursor_hide);
    defer if (settings.live) w.writeAll(term.cursor_show) catch {};
    while (true) {
        _ = arena.reset(.retain_capacity);
        const state = try state_of(session, arena.allocator(), job);
        if (!state.running or interrupted.load(.acquire)) break;
        if (settings.live) {
            const seen = try session.probe_get(arena.allocator(), job);
            try term.lines_erase(w, lines);
            lines = try view.write(w, seen.points, summary_of(state, null), .{
                .color = settings.color,
            });
            try w.flush();
        }
        sleep_ms(@min(settings.options.interval_ms, 200));
    }
    const reason = session.probe_stop(job) catch |err| {
        return ctx.fail("probing failed: {s}", .{hint(err)});
    };
    _ = arena.reset(.retain_capacity);
    const state = try state_of(session, arena.allocator(), job);
    const seen = try session.probe_get(arena.allocator(), job);
    if (settings.live) try term.lines_erase(w, lines);
    _ = try view.write(w, seen.points, summary_of(state, reason), .{ .color = settings.color });
    try w.flush();
}

fn state_of(session: *client.Session, arena: std.mem.Allocator, job: u64) !client.ProbeState {
    for (try session.probe_list(arena)) |state| {
        if (state.job == job) return state;
    }
    return error.ProbeUnknown;
}

fn summary_of(state: client.ProbeState, reason: ?@import("shared").protocol.RunStop) view.Summary {
    const info = state.info;
    return .{
        .function = if (info) |found| found.function else "?",
        .path = if (info) |found| found.path else "?",
        .pid = state.pid,
        .elapsed_ms = state.elapsed_ms,
        .reason = reason,
    };
}

fn settings_read(ctx: *cli.Context) error{InvalidUsage}!Settings {
    if (!ctx.isSet("pid")) return ctx.usageFail("--pid is needed: the process to probe", .{});
    if (!ctx.isSet("function")) return ctx.usageFail("--function is needed: what to time", .{});
    const pid = ctx.getInt("pid");
    if (pid <= 0 or pid > std.math.maxInt(i32)) {
        return ctx.usageFail("--pid must be a process id (got {d})", .{pid});
    }
    const interval = ctx.getInt("interval");
    if (interval < 10 or interval > std.time.ms_per_min) {
        return ctx.usageFail("--interval must be 10 ms to a minute (got {d} ms)", .{interval});
    }
    const duration = ctx.getInt("duration");
    if (duration < 0) return ctx.usageFail("--duration must be 0 or more (got {d})", .{duration});
    const terminal = std.Io.File.stdout().isTty(ctx.io) catch false;
    return .{
        .options = .{
            .pid = @intCast(pid),
            .function = ctx.getString("function"),
            .module = if (ctx.isSet("module")) ctx.getString("module") else null,
            .interval_ms = @intCast(interval),
            .duration_s = @intCast(duration),
        },
        .live = terminal and !ctx.getBool("no-live"),
        .color = try flags.color_read(ctx),
    };
}

fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.FunctionNotFound => "no such function in the process: it may be inlined " ++
            "(no call to probe), or named differently (use the names nusku prof shows)",
        error.FunctionAmbiguous => "the name is in more than one file: pick one with --module",
        error.GoProgram => "Go programs cannot take return probes: their runtime moves stacks",
        error.PermissionDenied => "function probes need root or CAP_SYS_ADMIN: " ++
            "the kernel lets nothing less open a uprobe",
        error.PermissionDenied => "run as root, or grant CAP_BPF, CAP_PERFMON and CAP_SYSLOG",
        error.ProcessNotFound, error.InvalidPid => "no process with that pid",
        error.NotSupported => "this kernel cannot put a probe there",
        error.ProbesFull => "too many probes running: stop one first",
        else => @errorName(err),
    };
}

fn sleep_ms(ms: u32) void {
    const pause = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&pause, null);
}
