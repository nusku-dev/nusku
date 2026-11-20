//! `nusku watch`: profile processes in one session and look at any of them

const std = @import("std");
const cli = @import("cli");
const log = @import("log");
const client = @import("client");
const flags = @import("flags.zig");
const prof = @import("prof.zig");
const term = @import("../term/term.zig");
const view = @import("../view/view.zig").profile;

const linux = std.os.linux;
const Writer = std.Io.Writer;

pub const cmd: cli.Command = .{
    .name = "watch",
    .short = "Profile processes in one session, list them, and watch any of them live",
    .long =
    \\Opens a session that keeps profiling in the background while you work:
    \\
    \\  prof <pid> [seconds]                profile a running process
    \\  launch [--keep] <program> [args]    start a program and profile it
    \\  watch                               list the profiles, with their ids
    \\  watch <id>                          watch one live; Enter goes back
    \\  stop <id>                           stop profiling (never the process)
    \\  quit                                end the session
    \\
    \\A launched program is stopped when its profiling ends, unless --keep is
    \\given. Profiling needs root, or CAP_BPF, CAP_PERFMON, CAP_SYSLOG and
    \\CAP_CHECKPOINT_RESTORE (the last names programs rebuilt while they run).
    ,
    .flags = &.{
        .{
            .name = "top",
            .kind = .int,
            .default = "15",
            .help = "Functions to show in a live view",
        },
        flags.color,
    },
    .run = run,
};

const user: client.UserId = 1;
var interrupted = std.atomic.Value(bool).init(false);

fn on_interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Shell = struct {
    ctx: *cli.Context,
    session: *client.Session,
    options: view.Options,
    names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    input: Input = .{},
};

fn run(ctx: *cli.Context) anyerror!void {
    if (!ctx.isSet("log-level") and !ctx.getBool("verbose")) {
        if (log.getDefault()) |logger| logger.setLevel(.warn);
    }
    try flags.log_apply(ctx);
    const top = ctx.getInt("top");
    if (top < 1) return ctx.usageFail("--top must be at least 1 (got {d})", .{top});

    const action = std.posix.Sigaction{
        .handler = .{ .handler = on_interrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);

    const session = try std.heap.smp_allocator.create(client.Session);
    defer std.heap.smp_allocator.destroy(session);
    session.init(std.heap.smp_allocator, .{}) catch |err| {
        return ctx.fail("cannot start a session: {t}", .{err});
    };

    defer session.deinit();

    var shell = Shell{
        .ctx = ctx,
        .session = session,
        .options = .{ .top = @intCast(top), .color = try flags.color_read(ctx) },
    };

    const w = ctx.stdout;
    try w.writeAll("nusku watch: type help for the commands, quit to end.\n");
    while (true) {
        try w.writeAll("nusku> ");
        try w.flush();
        const line = shell.input.line() orelse break;
        interrupted.store(false, .release);
        if (!try command_run(&shell, line)) break;
    }
    try w.writeAll("\n");
    try w.flush();
}

fn command_run(shell: *Shell, line: []const u8) !bool {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const name = words.next() orelse return true;
    const w = shell.ctx.stdout;
    if (eq(name, "quit") or eq(name, "exit")) return false;
    if (eq(name, "help")) {
        try w.writeAll(cmd.long.?);
        try w.writeAll("\n");
    } else if (eq(name, "prof")) {
        try prof_run(shell, &words);
    } else if (eq(name, "launch")) {
        try launch_run(shell, &words);
    } else if (eq(name, "watch")) {
        if (words.next()) |id| try live_run(shell, id) else try list_write(shell);
    } else if (eq(name, "stop")) {
        try stop_run(shell, words.next());
    } else {
        try w.print("unknown command \"{s}\": type help\n", .{name});
    }
    return true;
}

fn prof_run(shell: *Shell, words: *std.mem.TokenIterator(u8, .any)) !void {
    const w = shell.ctx.stdout;
    const pid_text = words.next() orelse return w.writeAll("usage: prof <pid> [seconds]\n");
    const pid = std.fmt.parseInt(u32, pid_text, 10) catch return w.writeAll("not a pid\n");
    const seconds = if (words.next()) |text| std.fmt.parseInt(u32, text, 10) catch {
        return w.writeAll("not a number of seconds\n");
    } else 0;
    const options = options_of(pid, seconds);
    const started = shell.session.profile_start(options, user) catch |err| return failed(w, err);
    var buffer: [64]u8 = undefined;
    const name = prof.process_name(pid, &buffer) orelse "unknown";
    try name_keep(shell, started.job, name);
    const joined = if (started.joined) " (already running: joined it)" else "";
    try w.print("profile {d}: {s} [pid {d}]{s}\n", .{ started.job, name, pid, joined });
}

fn launch_run(shell: *Shell, words: *std.mem.TokenIterator(u8, .any)) !void {
    const w = shell.ctx.stdout;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    var keep = false;
    while (words.next()) |word| {
        if (argv.items.len == 0 and eq(word, "--keep")) {
            keep = true;
            continue;
        }
        try argv.append(arena.allocator(), word);
    }
    if (argv.items.len == 0) return w.writeAll("usage: launch [--keep] <program> [args]\n");
    var options = options_of(null, 0);
    options.program = .{ .argv = argv.items, .keep_running = keep };
    const started = shell.session.profile_start(options, user) catch |err| return failed(w, err);
    const name = std.fs.path.basename(argv.items[0]);
    try name_keep(shell, started.job, name);
    const ending = if (keep) "kept running" else "stopped";
    const text = "profile {d}: {s} [pid {d}] launched, {s} when profiling ends\n";
    try w.print(text, .{ started.job, name, started.pid, ending });
}

fn name_keep(shell: *Shell, job: u64, name: []const u8) !void {
    const gpa = std.heap.smp_allocator;
    try shell.names.put(gpa, job, try gpa.dupe(u8, name));
}

fn stop_run(shell: *Shell, id_text: ?[]const u8) !void {
    const w = shell.ctx.stdout;
    const job = job_read(w, id_text) catch return;
    const stopped = shell.session.profile_stop(job, user) catch |err| return failed(w, err);
    if (stopped.reason == null) {
        try w.print("profile {d}: left it, still watched by {d} more\n", .{ job, stopped.users });
    } else {
        try w.print("profile {d}: stopped\n", .{job});
    }
}

fn list_write(shell: *Shell) !void {
    const w = shell.ctx.stdout;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const states = try shell.session.profiles(arena.allocator());
    if (states.len == 0) return w.writeAll("no profiles yet: prof <pid> or launch <program>\n");
    const style = term.Style{ .color = shell.options.color };
    try w.print("{s}{s:>4}  {s:>8}  {s:<20}  {s:<16}  {s:>8}  {s:>9}{s}\n", .{
        style.on(term.dim), "ID", "PID", "PROGRAM", "STATE", "ELAPSED", "SAMPLES", style.off(),
    });
    for (states) |state| {
        const name = shell.names.get(state.job) orelse "?";
        const samples = if (state.profile) |profile| profile.samples else 0;
        try w.print("{d:>4}  {d:>8}  {s:<20}  {s:<16}  {d:>6}.{d}s  {d:>9}\n", .{
            state.job,
            state.pid,
            name[0..@min(name.len, 20)],
            state_text(state),
            state.elapsed_ms / 1000,
            state.elapsed_ms % 1000 / 100,
            samples,
        });
    }
}

fn state_text(state: client.ProfileState) []const u8 {
    if (state.running) return "live";
    if (state.failure != null) return "failed";
    const reason = state.reason orelse return "ended";
    return switch (reason) {
        .duration => "duration reached",
        .target_exited => "process exited",
        .cancelled => "stopped",
    };
}

fn live_run(shell: *Shell, id_text: []const u8) !void {
    const w = shell.ctx.stdout;
    const job = job_read(w, id_text) catch return;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var lines: usize = 0;
    try w.writeAll(term.cursor_hide);
    defer w.writeAll(term.cursor_show) catch {};
    while (true) {
        _ = arena.reset(.retain_capacity);
        const state = state_find(shell, arena.allocator(), job) catch |err| return failed(w, err);
        const asked = shell.session.profile_get(arena.allocator(), job, 0);
        const got = asked catch |err| return failed(w, err);
        const profile = if (got) |delta| delta.profile else return;
        var summary = view.Summary{
            .pid = state.pid,
            .name = shell.names.get(job),
            .elapsed_ms = state.elapsed_ms,
            .reason = if (state.running) null else state.reason orelse .cancelled,
            .live_hint = "Enter or Ctrl-C to go back",
        };
        if (!state.running) {
            try term.lines_erase(w, lines);
            try view.write(w, arena.allocator(), &profile, summary, shell.options);
            return w.flush();
        }
        summary.reason = null;
        const options = shell.options;
        const drawn = view.live_write(w, arena.allocator(), &profile, summary, options, lines);
        lines = drawn catch lines;
        try w.flush();
        if (shell.input.wait(1000) or interrupted.swap(false, .acq_rel)) return w.writeAll("\n");
    }
}

fn state_find(shell: *Shell, arena: std.mem.Allocator, job: u64) !client.ProfileState {
    for (try shell.session.profiles(arena)) |state| {
        if (state.job == job) return state;
    }
    return error.ProfileUnknown;
}

fn job_read(w: *Writer, text: ?[]const u8) !u64 {
    const id = text orelse {
        try w.writeAll("which profile? give its id: watch lists them\n");
        return error.NoId;
    };
    return std.fmt.parseInt(u64, id, 10) catch {
        try w.writeAll("not a profile id: watch lists them\n");
        return error.NoId;
    };
}

fn options_of(pid: ?u32, seconds: u32) client.ProfileOptions {
    return .{
        .pid = pid,
        .metrics = .initOne(.cpu),
        .interval_ms = 1000,
        .duration_s = seconds,
    };
}

fn failed(w: *Writer, err: anyerror) !void {
    const why: []const u8 = switch (err) {
        error.PermissionDenied => "run as root, or grant CAP_BPF, CAP_PERFMON, CAP_SYSLOG" ++
            " and CAP_CHECKPOINT_RESTORE",
        error.ProcessNotFound, error.InvalidPid => "no process with that pid",
        error.ProfileUnknown => "no profile with that id: watch lists them",
        error.ProfilesFull => "too many profiles running: stop one first",
        error.ProgramNotFound => "no such program (give a path, or a name on PATH)",
        error.NotExecutable => "the file cannot be run",
        error.ExitedAtOnce => "it ended before it could be profiled",
        error.NotJoined => "this session did not start that profile",
        else => @errorName(err),
    };
    try w.print("cannot: {s}\n", .{why});
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Lines from stdin, read straight from the descriptor so a live view can wait on it.
const Input = struct {
    buffer: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn line(input: *Input) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, input.buffer[input.start..input.end], '\n')) |at| {
                const found = input.buffer[input.start..][0..at];
                input.start += at + 1;
                return found;
            }
            if (input.start > 0) {
                std.mem.copyForwards(u8, &input.buffer, input.buffer[input.start..input.end]);
                input.end -= input.start;
                input.start = 0;
            }
            if (input.end == input.buffer.len) input.end = 0;
            const got = linux.read(0, input.buffer[input.end..].ptr, input.buffer.len - input.end);
            switch (linux.errno(got)) {
                .SUCCESS => if (got == 0) return null else {
                    input.end += got;
                },
                .INTR => if (interrupted.swap(false, .acq_rel)) return null,
                else => return null,
            }
        }
    }

    /// True when a line came within `timeout_ms`; the line is used up.
    fn wait(input: *Input, timeout_ms: i32) bool {
        if (std.mem.indexOfScalar(u8, input.buffer[input.start..input.end], '\n') != null) {
            _ = input.line();
            return true;
        }
        var poll = [_]linux.pollfd{.{ .fd = 0, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&poll, 1, timeout_ms);
        if (linux.errno(ready) != .SUCCESS or ready == 0) return false;
        _ = input.line();
        return true;
    }
};
