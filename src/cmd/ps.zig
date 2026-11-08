//! `nusku ps`: the processes of the machine, redrawn every interval on a terminal, else once.

const std = @import("std");
const cli = @import("cli");
const flags = @import("flags.zig");
const local = @import("../clients/local.zig");
const term = @import("../view/term.zig");
const view = @import("../view/processes.zig");
const Frame = @import("server").processes.Frame;

pub const cmd: cli.Command = .{
    .name = "ps",
    .short = "Watch the processes of this machine, with what they use",
    .long =
    \\Watch every process of this machine: its pid, user, CPU and memory, when it
    \\started, its threads and its command, the busiest first.
    \\
    \\On a terminal the table is redrawn after every --interval, until Ctrl-C, and
    \\fills the screen. Otherwise, or with --once, it is printed once and nusku
    \\exits. CPU is measured over --interval, so the first table comes after one.
    ,
    .flags = &.{
        .{
            .name = "interval",
            .kind = .int,
            .default = "1000",
            .help = "Milliseconds between two looks: the CPU of each process is measured over it",
        },
        .{
            .name = "top",
            .kind = .int,
            .help = "Processes to show; 0 shows all (default: what fits the screen, or 20)",
        },
        .{
            .name = "sort",
            .kind = .string,
            .default = "cpu",
            .help = "cpu, mem or pid",
        },
        .{
            .name = "once",
            .kind = .bool,
            .help = "Print the table once and exit, even on a terminal",
        },
        flags.color,
    },
    .run = run,
};

fn run(ctx: *cli.Context) anyerror!void {
    try flags.log_apply(ctx);
    const interval = ctx.getInt("interval");
    if (interval < 100 or interval > std.time.ms_per_min) {
        return ctx.usageFail("--interval must be 100 ms to a minute (got {d} ms)", .{interval});
    }
    const sort_text = ctx.getString("sort");
    const sort = std.meta.stringToEnum(view.Sort, sort_text) orelse
        return ctx.usageFail("--sort must be cpu, mem or pid (got \"{s}\")", .{sort_text});

    const terminal = std.Io.File.stdout().isTty(ctx.io) catch false;
    const size = if (terminal) term.size() else null;
    var options = view.Options{
        .sort = sort,
        .color = try flags.color_read(ctx),
        .live = terminal and !ctx.getBool("once"),
        .width = if (size) |known| known.cols else 0,
        .cpus = std.Thread.getCpuCount() catch 1,
    };
    options.top = try top_read(ctx, options.live, size);

    if (options.live) return live_run(ctx, @intCast(interval), options);
    const listed = local.processes(std.heap.smp_allocator, ctx.allocator, @intCast(interval));
    const frame = listed catch |err| {
        return ctx.fail("listing the processes failed: {t}", .{err});
    };
    _ = try view.write(ctx.stdout, ctx.allocator, &frame, options);
    try ctx.stdout.flush();
}

/// Until Ctrl-C, with the cursor hidden meanwhile.
fn live_run(ctx: *cli.Context, interval_ms: u32, options: view.Options) !void {
    var live = Live{ .ctx = ctx, .options = options };
    defer live.arena.deinit();
    try ctx.stdout.writeAll(term.cursor_hide);
    try ctx.stdout.flush();
    defer {
        ctx.stdout.writeAll(term.cursor_show) catch {};
        ctx.stdout.flush() catch {};
    }
    local.processes_watch(std.heap.smp_allocator, interval_ms, live.watcher()) catch |err| {
        return ctx.fail("watching the processes failed: {t}", .{err});
    };
}

/// As asked; else what fits the screen when live (the header takes 5 lines), or 20.
fn top_read(ctx: *cli.Context, live: bool, size: ?term.Size) error{InvalidUsage}!usize {
    if (ctx.isSet("top")) {
        const top = ctx.getInt("top");
        if (top < 0) return ctx.usageFail("--top must be 0 or more (got {d})", .{top});
        return @intCast(top);
    }
    if (live) {
        if (size) |known| return if (known.rows > 10) known.rows - 5 else 5;
    }
    return 20;
}

/// The table, drawn over the last one at every frame.
const Live = struct {
    ctx: *cli.Context,
    options: view.Options,
    /// Of the last table: what the next one draws over.
    lines: usize = 0,
    /// One table's memory, freed by the next.
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),

    fn watcher(live: *Live) local.ProcessesLive {
        return .{ .context = live, .show = show };
    }

    fn show(context: *anyopaque, frame: *const Frame) void {
        const live: *Live = @ptrCast(@alignCast(context));
        _ = live.arena.reset(.retain_capacity);
        const stdout = live.ctx.stdout;
        term.lines_erase(stdout, live.lines) catch return;
        // A table that cannot be drawn is skipped: the next frame tries again.
        live.lines = view.write(stdout, live.arena.allocator(), frame, live.options) catch 0;
        stdout.flush() catch {};
    }
};
