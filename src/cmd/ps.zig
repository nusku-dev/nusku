//! `nusku ps`: the processes of the machine.

const std = @import("std");
const cli = @import("cli");
const flags = @import("flags.zig");
const client = @import("client");
const interrupt = @import("interrupt.zig");
const term = @import("../term/term.zig");
const view = @import("../view/view.zig").processes;
const Frame = @import("shared").protocol.ProcessFrame;

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
    };
    options.top = try top_read(ctx, options.live, size);
    interrupt.arm();

    if (options.live) return live_run(ctx, @intCast(interval), options);
    const listed = client.processes(std.heap.smp_allocator, ctx.allocator, @intCast(interval));
    const frame = listed catch |err| {
        return ctx.fail("listing the processes failed: {t}", .{err});
    };
    _ = try view.write(ctx.stdout, ctx.allocator, &frame, options);
    try ctx.stdout.flush();
}

fn live_run(ctx: *cli.Context, interval_ms: u32, options: view.Options) !void {
    var live = Live{ .ctx = ctx, .options = options };
    defer live.arena.deinit();
    try ctx.stdout.writeAll(term.cursor_hide);
    try ctx.stdout.flush();
    defer {
        ctx.stdout.writeAll(term.cursor_show) catch {};
        ctx.stdout.flush() catch {};
    }
    client.processes_watch(std.heap.smp_allocator, interval_ms, live.watcher()) catch |err| {
        return ctx.fail("watching the processes failed: {t}", .{err});
    };
}

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

const Live = struct {
    ctx: *cli.Context,
    options: view.Options,
    lines: usize = 0,
    arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),

    fn watcher(live: *Live) client.ProcessesLive {
        return .{ .context = live, .show = show };
    }

    fn show(context: *anyopaque, frame: *const Frame) void {
        const live: *Live = @ptrCast(@alignCast(context));
        _ = live.arena.reset(.retain_capacity);
        const stdout = live.ctx.stdout;
        term.lines_erase(stdout, live.lines) catch return;
        live.lines = view.write(stdout, live.arena.allocator(), frame, live.options) catch 0;
        stdout.flush() catch {};
    }
};
