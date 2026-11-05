const std = @import("std");
const log = @import("log");
const cli = @import("cli");
const server = @import("server");
const utils = @import("_utils.zig");
const local = @import("../clients/local.zig");
const report = @import("../report.zig");
const slog = log.scope("prof");

const Metric = server.Metric;

pub const cmd: cli.Command = .{
    .name = "prof",
    .short = "Profile a running process or launch one to profile",
    .long =
    \\Profile a Linux process and collect detailed runtime performance data.
    \\
    \\You can attach to an existing process with --pid, or launch a new
    \\process with --exec. When launching a process, arguments after
    \\the executable path are passed directly to it.
    \\
    \\Profiling runs until --duration ends, the process exits, or Ctrl-C.
    \\On a terminal, the top functions are shown live while it runs. Then
    \\the profile is printed: the functions that took the most time on the
    \\CPU, and the call tree. A launched process that is still running then
    \\is stopped.
    ,
    .flags = &.{
        .{
            .name = "exec",
            .short = 'e',
            .kind = .string,
            .help = "Path to the executable to launch and profile",
        },
        .{
            .name = "pid",
            .short = 'p',
            .kind = .int,
            .help = "PID of an already running process to profile",
        },
        .{
            .name = "metrics",
            .kind = .string,
            .default = "cpu",
            //  .default = "cpu,offcpu,mem,io,net,locks,sched",
            .help = "Comma-separated list of metrics to collect",
        },
        .{
            .name = "interval",
            .kind = .int,
            .default = "1000",
            .help = "Milliseconds between two reports of the run (samples are taken at 99 Hz)",
        },
        .{
            .name = "duration",
            .kind = .int,
            .default = "0",
            .help = "How long to profile in seconds; 0 means run until stopped",
        },
        .{
            .name = "top",
            .kind = .int,
            .default = "20",
            .help = "How many functions to show",
        },
        .{
            .name = "cutoff",
            .kind = .int,
            .default = "1",
            .help = "Hide call tree branches under this percent of the samples; 0 shows all",
        },
        .{
            .name = "color",
            .kind = .string,
            .default = "auto",
            .help = "auto (when the output is a terminal and NO_COLOR is unset), always, never",
        },
        .{
            .name = "no-live",
            .kind = .bool,
            .help = "Do not show the profile while it runs, only at the end",
        },
        .{
            .name = "folded",
            .kind = .string,
            .help = "Also write the stacks to this file, in the folded format of flame graph tools",
        },
    },
    .usage_args = "[args...]",
    .args = .any,
    .run = run,
};

fn run(ctx: *cli.Context) anyerror!void {
    try utils.logConfig(ctx);
    const flags = try flags_read(ctx);

    // A launched process that is still running when profiling ends is stopped with it.
    var child: ?std.process.Child = null;
    defer if (child) |*launched| launched.kill(ctx.io);
    const target: u32 = flags.pid orelse target: {
        child = try launch(ctx, ctx.getString("exec"), ctx.args);
        break :target @intCast(child.?.id.?);
    };
    // Now, while the process is surely there.
    var name_buffer: [64]u8 = undefined;
    const name = if (child != null)
        std.fs.path.basename(ctx.getString("exec"))
    else
        local.process_name(target, &name_buffer);
    const options = report.Options{
        .top = flags.top,
        .cutoff_tenths = flags.cutoff_tenths,
        .color = flags.color,
    };

    // The live view redraws itself: only on a terminal.
    const terminal = std.Io.File.stdout().isTty(ctx.io) catch false;
    var view = LiveView{ .ctx = ctx, .pid = target, .name = name, .options = options };
    defer view.arena.deinit();
    const live: ?local.Live = if (terminal and !flags.no_live)
        view.live(flags.interval_ms)
    else
        null;

    // The server frees as it goes (uploads, tables), so it gets an allocator that does, and
    // one that threads can share. The arena only holds the profile.
    const result = local.profile(std.heap.smp_allocator, ctx.allocator, .{
        .pid = target,
        .metrics = flags.metrics,
        .interval_ms = flags.interval_ms,
        .duration_s = flags.duration_s,
    }, live) catch |err| {
        try report.live_clear(ctx.stdout, view.lines);
        const advice = hint(err);
        return ctx.fail("profiling pid {d} failed: {t}{s}{s}", .{
            target,
            err,
            if (advice.len > 0) ": " else "",
            advice,
        });
    };

    if (flags.folded) |path| try folded_save(ctx, path, &result.profile);
    // The final report takes the place of the live view.
    try report.live_clear(ctx.stdout, view.lines);
    try report.write(ctx.stdout, ctx.allocator, &result.profile, .{
        .pid = target,
        .name = name,
        .elapsed_ms = result.elapsed_ms,
        .reason = result.reason,
    }, options);
    try ctx.stdout.flush();
}

/// The profile as it grows, drawn over itself on the terminal at every report.
const LiveView = struct {
    ctx: *cli.Context,
    pid: u32,
    name: ?[]const u8,
    options: report.Options,
    /// Lines of the last view: what the next one draws over.
    lines: usize = 0,
    /// One view's memory, freed by the next.
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),

    fn live(view: *LiveView, every_ms: u32) local.Live {
        return .{ .context = view, .every_ms = every_ms, .show = show };
    }

    fn show(context: *anyopaque, profile: *const server.Profile, elapsed_ms: u64) void {
        const view: *LiveView = @ptrCast(@alignCast(context));
        _ = view.arena.reset(.retain_capacity);
        const summary = report.Summary{
            .pid = view.pid,
            .name = view.name,
            .elapsed_ms = elapsed_ms,
            .reason = null,
        };
        const stdout = view.ctx.stdout;
        // A view that cannot be drawn is skipped: the final report still comes.
        const arena = view.arena.allocator();
        const drawn = report.live_write(stdout, arena, profile, summary, view.options, view.lines);
        view.lines = drawn catch view.lines;
    }
};

/// The stacks in the folded format, for flame graph tools, in the file at `path`.
fn folded_save(ctx: *cli.Context, path: []const u8, profile: *const server.Profile) !void {
    const file = std.Io.Dir.cwd().createFile(ctx.io, path, .{}) catch |err| {
        return ctx.fail("cannot write {s}: {t}", .{ path, err });
    };
    defer file.close(ctx.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try report.folded_write(&writer.interface, ctx.allocator, profile);
    try writer.interface.flush();
    slog.debug("folded stacks written", .{ .path = path, .stacks = profile.stacks.len });
}

/// The flags, checked.
const Flags = struct {
    /// Null with --exec: the pid is the launched process's.
    pid: ?u32,
    metrics: std.EnumSet(Metric),
    interval_ms: u32,
    duration_s: u32,
    top: usize,
    cutoff_tenths: u64,
    color: bool,
    folded: ?[]const u8,
    no_live: bool,
};

fn flags_read(ctx: *cli.Context) error{InvalidUsage}!Flags {
    const has_exec = ctx.isSet("exec");
    const has_pid = ctx.isSet("pid");
    slog.debug("starting prof command", .{ .exec = has_exec, .pid = has_pid });

    if (!has_exec and !has_pid) return ctx.usageFail("one of --exec or --pid is required", .{});
    if (has_exec and has_pid) {
        return ctx.usageFail("--exec and --pid cannot be used together", .{});
    }
    if (has_pid and ctx.args.len > 0) {
        return ctx.usageFail("arguments after -- only apply to --exec", .{});
    }

    const pid = ctx.getInt("pid");
    if (has_pid and (pid <= 0 or pid > std.math.maxInt(i32))) {
        return ctx.usageFail("--pid must be a process id (got {d})", .{pid});
    }
    const interval = ctx.getInt("interval");
    if (interval < 10 or interval > std.time.ms_per_hour) {
        return ctx.usageFail("--interval must be 10 ms to an hour (got {d} ms)", .{interval});
    }
    const duration = ctx.getInt("duration");
    if (duration < 0 or duration > std.math.maxInt(u32)) {
        return ctx.usageFail("--duration must be 0 or more seconds (got {d})", .{duration});
    }
    const top = ctx.getInt("top");
    if (top < 1) return ctx.usageFail("--top must be at least 1 (got {d})", .{top});
    const cutoff = ctx.getInt("cutoff");
    if (cutoff < 0 or cutoff > 100) {
        return ctx.usageFail("--cutoff must be 0 to 100 percent (got {d})", .{cutoff});
    }
    const color = try color_read(ctx);

    const metrics = try parseMetrics(ctx);
    slog.debug("profiling configuration validated", .{
        .interval_ms = interval,
        .duration_s = duration,
        .metrics = ctx.getString("metrics"),
    });
    return .{
        .pid = if (has_pid) @intCast(pid) else null,
        .metrics = metrics,
        .interval_ms = @intCast(interval),
        .duration_s = @intCast(duration),
        .top = @intCast(top),
        .cutoff_tenths = @intCast(cutoff * 10),
        .color = color,
        .folded = if (ctx.isSet("folded")) ctx.getString("folded") else null,
        .no_live = ctx.getBool("no-live"),
    };
}

/// Whether the report gets colors: always, never, or when it goes to a terminal and the user
/// has not set NO_COLOR (no-color.org).
fn color_read(ctx: *cli.Context) error{InvalidUsage}!bool {
    const text = ctx.getString("color");
    if (std.mem.eql(u8, text, "always")) return true;
    if (std.mem.eql(u8, text, "never")) return false;
    if (!std.mem.eql(u8, text, "auto")) {
        return ctx.usageFail("--color must be auto, always or never (got \"{s}\")", .{text});
    }
    const no_color = std.c.getenv("NO_COLOR") != null;
    return log.shouldColor(ctx.io, std.Io.File.stdout(), no_color);
}

/// Starts `exec` with `args`, to profile it from its start.
fn launch(ctx: *cli.Context, exec: []const u8, args: []const []const u8) !std.process.Child {
    const argv = try ctx.allocator.alloc([]const u8, args.len + 1);
    argv[0] = exec;
    @memcpy(argv[1..], args);

    const child = std.process.spawn(ctx.io, .{ .argv = argv }) catch |err| {
        return ctx.fail("cannot launch {s}: {t}", .{ exec, err });
    };
    slog.info("process launched", .{ .exec = exec, .args = args.len, .pid = child.id.? });
    return child;
}

/// What to do about an error the user can fix.
fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.PermissionDenied => "run as root, or grant CAP_BPF, CAP_PERFMON and CAP_SYSLOG",
        error.ProcessNotFound => "no process with that pid",
        error.NotSupported => "the kernel is too old for nusku: it needs Linux 5.3 or newer",
        error.MetricNotImplemented => "only the cpu metric exists so far",
        else => "",
    };
}

fn parseMetrics(ctx: *cli.Context) error{InvalidUsage}!std.EnumSet(Metric) {
    var set: std.EnumSet(Metric) = .initEmpty();
    var parts = std.mem.splitScalar(u8, ctx.getString("metrics"), ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        const metric = std.meta.stringToEnum(Metric, name) orelse
            return ctx.usageFail(
                "unknown metric \"{s}\" (valid: cpu, offcpu, mem, io, net, locks, sched)",
                .{name},
            );
        set.insert(metric);
    }
    return set;
}
