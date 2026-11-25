//! `nusku prof`: profiles a process.

const std = @import("std");
const log = @import("log");
const cli = @import("cli");
const server = @import("server");
const flags = @import("flags.zig");
const client = @import("client");
const interrupt = @import("interrupt.zig");
const term = @import("../term/term.zig");
const view = @import("../view/view.zig").profile;

const slog = log.scope("prof");
const protocol = @import("shared").protocol;
const Metric = protocol.Metric;

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
    \\CPU, the call tree, and what the profile could not see. A launched process
    \\that is still running then is stopped, unless --keep-running is given. Its
    \\input is empty and its output is discarded.
    \\
    \\With --save, the profile is also kept as a saved run, in the same place
    \\the app keeps them (~/.local/share/nusku/runs; under sudo, the home of
    \\the user who ran sudo), to open or compare in the app.
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
        flags.color,
        .{
            .name = "no-live",
            .kind = .bool,
            .help = "Do not show the profile while it runs, only at the end",
        },
        .{
            .name = "keep-running",
            .kind = .bool,
            .help = "Leave a launched program running when profiling ends",
        },
        .{
            .name = "from",
            .kind = .int,
            .help = "Show only the run from this many seconds after its start",
        },
        .{
            .name = "to",
            .kind = .int,
            .help = "Show only the run up to this many seconds after its start",
        },
        .{
            .name = "repeat",
            .kind = .int,
            .default = "1",
            .help = "Launch and profile the program this many times, saved as one series",
        },
        .{
            .name = "save",
            .kind = .string,
            .help = "Keep the profile as a saved run with this label, to open in the app",
        },
        .{
            .name = "note",
            .kind = .string,
            .help = "A note for the saved run: what changed, how it was run",
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
    try flags.log_apply(ctx);
    const settings = try settings_read(ctx);
    interrupt.arm();
    if (settings.repeat > 1) return @import("prof_repeat.zig").run(ctx, settings);

    const program: ?protocol.Program = if (settings.pid == null) .{
        .argv = try argv_of(ctx, ctx.getString("exec"), ctx.args),
        .keep_running = settings.keep_running,
    } else null;
    var name_buffer: [64]u8 = undefined;
    const name = if (program != null)
        std.fs.path.basename(ctx.getString("exec"))
    else
        process_name(settings.pid.?, &name_buffer);
    const command = if (program) |launched|
        try std.mem.join(ctx.allocator, " ", launched.argv)
    else
        try command_of(ctx, settings.pid.?);

    const terminal = std.Io.File.stdout().isTty(ctx.io) catch false;
    var live = Live{ .ctx = ctx, .name = name, .options = settings.view };
    defer live.arena.deinit();
    const watcher: ?client.Live = if (terminal and !settings.no_live)
        live.watcher(settings.interval_ms)
    else
        null;

    const result = client.profile(std.heap.smp_allocator, ctx.allocator, .{
        .pid = settings.pid,
        .program = program,
        .metrics = settings.metrics,
        .interval_ms = settings.interval_ms,
        .duration_s = settings.duration_s,
        .from_ms = settings.from_ms,
        .to_ms = settings.to_ms,
    }, watcher) catch |err| {
        try term.lines_erase(ctx.stdout, live.lines);
        if (err == error.EmptyRange) {
            return ctx.fail("no report of the run falls between --from and --to", .{});
        }
        const advice = hint(err);
        const separator = if (advice.len > 0) ": " else "";
        const launched = program orelse return ctx.fail("profiling pid {d} failed: {t}{s}{s}", .{
            settings.pid.?,
            err,
            separator,
            advice,
        });
        const exec = launched.argv[0];
        if (launch_failure(err)) |reason| return ctx.fail("cannot launch {s}: {s}", .{ exec, reason });
        return ctx.fail("profiling {s} failed: {t}{s}{s}", .{ exec, err, separator, advice });
    };

    if (settings.folded) |path| try folded_save(ctx, path, &result.profile);
    try term.lines_erase(ctx.stdout, live.lines);
    try view.write(ctx.stdout, ctx.allocator, &result.profile, .{
        .pid = result.pid,
        .name = name,
        .elapsed_ms = result.elapsed_ms,
        .reason = result.reason,
        .part = part_of(settings),
    }, settings.view);

    if (settings.save) |label| try run_save(ctx, label, settings.note, .{
        .program = name orelse "",
        .command = command,
        .pid = result.pid,
    }, &result);

    try ctx.stdout.flush();
}

pub const Program = struct { program: []const u8, command: []const u8, pid: u32 };

pub const Series = struct { name: []const u8, repeat: u32, repeats: u32 };

pub fn run_save(
    ctx: *cli.Context,
    label: []const u8,
    note: []const u8,
    program: Program,
    result: *const client.Result,
) !void {
    const saved = try run_keep(ctx, label, note, program, result, null);
    try ctx.stdout.print("\n  Saved as \"{s}\" in {s}: open it in the app under Saved runs.\n", .{
        saved.meta.label,
        saved.dir,
    });
}

pub const Kept = struct { meta: client.store.Meta, dir: []const u8 };

pub fn run_keep(
    ctx: *cli.Context,
    label: []const u8,
    note: []const u8,
    program: Program,
    result: *const client.Result,
    series: ?Series,
) !Kept {
    const arena = ctx.allocator;
    const owner = client.store.sudo_owner(arena);
    var store: client.store.StoreRuns = undefined;
    store.init(arena, null, owner) catch |err| {
        return ctx.fail("cannot save the run: no runs folder ({t})", .{err});
    };
    const profile = &result.profile;
    const first = if (profile.windows.len > 0) profile.windows[0].start_unix_ns else 0;
    const saved = store.save(arena, .{
        .label = label,
        .note = note,
        .program = program.program,
        .command = program.command,
        .pid = program.pid,
        .started_unix_ms = first / std.time.ns_per_ms,
        .elapsed_ms = result.elapsed_ms,
        .samples = profile.samples,
        .sample_hz = profile.sample_hz,
        .series = if (series) |s| s.name else "",
        .repeat = if (series) |s| s.repeat else 0,
        .repeats = if (series) |s| s.repeats else 0,
    }, try client.compact.json_of(arena, profile)) catch |err| {
        return ctx.fail("cannot save the run: {t}", .{err});
    };
    return .{ .meta = saved, .dir = store.dir };
}

/// The command line of a process, its arguments joined by spaces; empty if unreadable.
pub fn command_of(ctx: *cli.Context, pid: u32) ![]const u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch unreachable;
    var file = @import("shared").File.open(path) catch return "";
    defer file.deinit();
    const buffer = try ctx.allocator.alloc(u8, 4096);
    const got = file.read_at(buffer, 0) catch return "";
    const text = std.mem.trimEnd(u8, buffer[0..got], "\x00");
    for (@constCast(text)) |*byte| if (byte.* == 0) {
        byte.* = ' ';
    };
    return text;
}

const Live = struct {
    ctx: *cli.Context,
    name: ?[]const u8,
    options: view.Options,
    lines: usize = 0,
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),

    fn watcher(live: *Live, every_ms: u32) client.Live {
        return .{ .context = live, .every_ms = every_ms, .show = show };
    }

    fn show(
        context: *anyopaque,
        profile: *const server.Profile,
        pid: u32,
        elapsed_ms: u64,
    ) void {
        const live: *Live = @ptrCast(@alignCast(context));
        _ = live.arena.reset(.retain_capacity);
        const summary = view.Summary{
            .pid = pid,
            .name = live.name,
            .elapsed_ms = elapsed_ms,
            .reason = null,
        };
        const stdout = live.ctx.stdout;
        const arena = live.arena.allocator();
        const drawn = view.live_write(stdout, arena, profile, summary, live.options, live.lines);
        live.lines = drawn catch live.lines;
    }
};

fn folded_save(ctx: *cli.Context, path: []const u8, profile: *const server.Profile) !void {
    const file = std.Io.Dir.cwd().createFile(ctx.io, path, .{}) catch |err| {
        return ctx.fail("cannot write {s}: {t}", .{ path, err });
    };
    defer file.close(ctx.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try view.folded_write(&writer.interface, ctx.allocator, profile);
    try writer.interface.flush();
    slog.debug("folded stacks written", .{ .path = path, .stacks = profile.stacks.len });
}

pub const Settings = struct {
    repeat: u32,
    pid: ?u32,
    metrics: std.EnumSet(Metric),
    interval_ms: u32,
    duration_s: u32,
    folded: ?[]const u8,
    save: ?[]const u8,
    note: []const u8,
    no_live: bool,
    keep_running: bool,
    from_ms: ?u64,
    to_ms: ?u64,
    view: view.Options,
};

fn repeat_read(ctx: *cli.Context, has_exec: bool) error{InvalidUsage}!u32 {
    const repeat = ctx.getInt("repeat");
    if (repeat < 1 or repeat > 100) {
        return ctx.usageFail("--repeat must be 1 to 100 (got {d})", .{repeat});
    }
    if (repeat == 1) return 1;
    if (!has_exec) {
        return ctx.usageFail("--repeat needs --exec: it launches the program each time", .{});
    }
    if (!ctx.isSet("save")) {
        return ctx.usageFail("--repeat needs --save: the runs are kept as a series", .{});
    }
    if (ctx.getBool("keep-running")) {
        return ctx.usageFail("--repeat and --keep-running do not go together", .{});
    }
    return @intCast(repeat);
}

fn settings_read(ctx: *cli.Context) error{InvalidUsage}!Settings {
    const has_exec = ctx.isSet("exec");
    const has_pid = ctx.isSet("pid");
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
    if (ctx.getBool("keep-running") and !has_exec) {
        return ctx.usageFail("--keep-running only applies to --exec", .{});
    }
    const from = if (ctx.isSet("from")) ctx.getInt("from") else 0;
    const to = if (ctx.isSet("to")) ctx.getInt("to") else std.math.maxInt(u32);
    if (from < 0 or to <= from) {
        const text = "--from and --to need 0 <= from < to (got {d} and {d})";
        return ctx.usageFail(text, .{ from, to });
    }
    if (ctx.isSet("save")) {
        const label = std.mem.trim(u8, ctx.getString("save"), " ");
        if (label.len == 0 or label.len > client.runs.label_bytes_max) {
            return ctx.usageFail("--save needs a label of 1 to {d} characters", .{
                client.store.label_bytes_max,
            });
        }
    }
    if (ctx.isSet("note") and !ctx.isSet("save")) {
        return ctx.usageFail("--note goes with --save", .{});
    }

    const top = ctx.getInt("top");
    if (top < 1) return ctx.usageFail("--top must be at least 1 (got {d})", .{top});
    const cutoff = ctx.getInt("cutoff");
    if (cutoff < 0 or cutoff > 100) {
        return ctx.usageFail("--cutoff must be 0 to 100 percent (got {d})", .{cutoff});
    }

    const settings = Settings{
        .pid = if (has_pid) @intCast(pid) else null,
        .metrics = try metrics_read(ctx),
        .interval_ms = @intCast(interval),
        .duration_s = @intCast(duration),
        .folded = if (ctx.isSet("folded")) ctx.getString("folded") else null,
        .save = if (ctx.isSet("save")) ctx.getString("save") else null,
        .note = if (ctx.isSet("note")) ctx.getString("note") else "",
        .no_live = ctx.getBool("no-live"),
        .keep_running = ctx.getBool("keep-running"),
        .repeat = try repeat_read(ctx, has_exec),
        .from_ms = if (ctx.isSet("from")) @as(u64, @intCast(from)) * std.time.ms_per_s else null,
        .to_ms = if (ctx.isSet("to")) @as(u64, @intCast(to)) * std.time.ms_per_s else null,
        .view = .{
            .top = @intCast(top),
            .cutoff_tenths = @intCast(cutoff * 10),
            .color = try flags.color_read(ctx),
        },
    };
    slog.debug("profiling configuration validated", .{
        .exec = has_exec,
        .interval_ms = settings.interval_ms,
        .duration_s = settings.duration_s,
        .metrics = ctx.getString("metrics"),
    });
    return settings;
}

fn metrics_read(ctx: *cli.Context) error{InvalidUsage}!std.EnumSet(Metric) {
    var set: std.EnumSet(Metric) = .initEmpty();
    var parts = std.mem.splitScalar(u8, ctx.getString("metrics"), ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        const metric = std.meta.stringToEnum(Metric, name) orelse return ctx.usageFail(
            "unknown metric \"{s}\" (valid: cpu, offcpu, mem, io, net, locks, sched)",
            .{name},
        );
        set.insert(metric);
    }
    return set;
}

pub fn argv_of(ctx: *cli.Context, exec: []const u8, args: []const []const u8) ![]const []const u8 {
    const argv = try ctx.allocator.alloc([]const u8, args.len + 1);
    argv[0] = exec;
    @memcpy(argv[1..], args);
    return argv;
}

pub fn launch_failure(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ProgramNotFound => "no such program (give a path, or a name on PATH)",
        error.NotExecutable => "the file cannot be run",
        error.TooManyArguments => "too many arguments, or one too long",
        error.ExitedAtOnce => "it ended before it could be profiled",
        error.LaunchFailed => "the system refused to start it",
        else => null,
    };
}

pub fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.PermissionDenied => "run as root, or grant CAP_BPF, CAP_PERFMON, CAP_SYSLOG" ++
            " and CAP_CHECKPOINT_RESTORE",
        error.ProcessNotFound => "no process with that pid",
        error.NotSupported => "the kernel is too old for nusku: it needs Linux 5.3 or newer",
        error.MetricNotImplemented => "only the cpu metric exists so far",
        else => "",
    };
}

fn part_of(settings: Settings) ?view.Summary.Part {
    if (settings.from_ms == null and settings.to_ms == null) return null;
    const ms_per_s = std.time.ms_per_s;
    return .{
        .from_s = (settings.from_ms orelse 0) / ms_per_s,
        .to_s = if (settings.to_ms) |to_ms| to_ms / ms_per_s else null,
    };
}

pub fn process_name(pid: u32, buffer: *[64]u8) ?[]const u8 {
    const linux = std.os.linux;
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/comm", .{pid}) catch unreachable;
    const opened = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const read = linux.read(fd, buffer, buffer.len);
    if (linux.errno(read) != .SUCCESS or read == 0) return null;
    return std.mem.trimEnd(u8, buffer[0..read], "\n");
}
