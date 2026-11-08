const std = @import("std");
const cli = @import("cli");
const log = @import("log");
const utils = @import("_utils.zig");
const local = @import("../clients/local.zig");
const view = @import("../ps_view.zig");
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
        .{
            .name = "color",
            .kind = .string,
            .default = "auto",
            .help = "auto (when the output is a terminal and NO_COLOR is unset), always, never",
        },
    },
    .run = run,
};

fn run(ctx: *cli.Context) anyerror!void {
    try utils.logConfig(ctx);
    const interval = ctx.getInt("interval");
    if (interval < 100 or interval > std.time.ms_per_min) {
        return ctx.usageFail("--interval must be 100 ms to a minute (got {d} ms)", .{interval});
    }
    const sort_text = ctx.getString("sort");
    const sort = std.meta.stringToEnum(view.Sort, sort_text) orelse
        return ctx.usageFail("--sort must be cpu, mem or pid (got \"{s}\")", .{sort_text});

    const terminal = std.Io.File.stdout().isTty(ctx.io) catch false;
    const size = if (terminal) terminal_size() else null;
    var options = view.Options{
        .sort = sort,
        .color = try color_read(ctx),
        .live = terminal and !ctx.getBool("once"),
        .width = if (size) |known| known.cols else 0,
        .cpus = std.Thread.getCpuCount() catch 1,
    };
    options.top = try top_read(ctx, options.live, size);

    if (!options.live) {
        const listed = local.processes(std.heap.smp_allocator, ctx.allocator, @intCast(interval));
        const frame = listed catch |err| {
            return ctx.fail("listing the processes failed: {t}", .{err});
        };
        _ = try view.write(ctx.stdout, ctx.allocator, &frame, options);
        try ctx.stdout.flush();
        return;
    }

    var live = Live{ .ctx = ctx, .options = options };
    defer live.arena.deinit();
    try ctx.stdout.writeAll(cursor_hide);
    try ctx.stdout.flush();
    defer {
        ctx.stdout.writeAll(cursor_show) catch {};
        ctx.stdout.flush() catch {};
    }
    local.processes_watch(std.heap.smp_allocator, @intCast(interval), live.watcher()) catch |err| {
        return ctx.fail("watching the processes failed: {t}", .{err});
    };
}

/// The rows to show: as asked, or what fits the screen when live (the header and a margin
/// take 5 lines), or 20 when printed once.
fn top_read(ctx: *cli.Context, live: bool, size: ?Size) error{InvalidUsage}!usize {
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
    /// Lines of the last table: what the next one draws over.
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
        // Up to where the last table started, and erase it: the next one takes its place.
        if (live.lines > 0) stdout.print("\x1b[{d}F\x1b[J", .{live.lines}) catch return;
        // A table that cannot be drawn is skipped: the next frame tries again.
        live.lines = view.write(stdout, live.arena.allocator(), frame, live.options) catch 0;
        stdout.flush() catch {};
    }
};

const cursor_hide = "\x1b[?25l";
const cursor_show = "\x1b[?25h";

const Size = struct { rows: usize, cols: usize };

/// The rows and columns of the terminal on stdout, or null when it does not say.
fn terminal_size() ?Size {
    var size: std.posix.winsize = undefined;
    const linux = std.os.linux;
    const result = linux.ioctl(std.posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (linux.errno(result) != .SUCCESS or size.row == 0 or size.col == 0) return null;
    return .{ .rows = size.row, .cols = size.col };
}

/// Whether the table gets colors: always, never, or when it goes to a terminal and the user
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
