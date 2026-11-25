//! `nusku prof --exec ... --repeat N --save <label>`: the same command profiled N times and
//! kept as one series, so a comparison can tell a real change from one run's luck.

const std = @import("std");
const cli = @import("cli");
const client = @import("client");
const prof = @import("prof.zig");
const term = @import("../term/term.zig");

pub fn run(ctx: *cli.Context, settings: prof.Settings) !void {
    const label = settings.save.?;
    const exec = ctx.getString("exec");
    const w = ctx.stdout;
    const seconds = try ctx.allocator.alloc(f64, settings.repeat);
    var done: u32 = 0;
    var dir: []const u8 = "";
    const style = term.Style{ .color = settings.view.color };
    try w.print("\n  {s}nusku{s}  {s} \u{00d7}{d}, saved as \"{s}\"\n\n", .{
        style.on(term.bold_cyan),
        style.off(),
        std.fs.path.basename(exec),
        settings.repeat,
        label,
    });
    try w.flush();
    while (done < settings.repeat) : (done += 1) {
        const once = try profile_once(ctx, settings, exec);
        if (once.result.reason == .cancelled) {
            const text = "  run {d}/{d} stopped before its end: not saved\n";
            try w.print(text, .{ done + 1, settings.repeat });
            break;
        }
        const profile = &once.result.profile;
        const name = try std.fmt.allocPrint(ctx.allocator, "{s} ({d}/{d})", .{
            label,
            done + 1,
            settings.repeat,
        });
        const kept = try prof.run_keep(ctx, name, settings.note, once.program, &once.result, .{
            .name = label,
            .repeat = done + 1,
            .repeats = settings.repeat,
        });
        dir = kept.dir;
        seconds[done] = if (profile.sample_hz > 0)
            @as(f64, @floatFromInt(profile.samples)) / @as(f64, @floatFromInt(profile.sample_hz))
        else
            0;
        try w.print("    run {d:>2}/{d}   {d:>7.2} s on the CPU   {d:>6} samples   {d:.1} s\n", .{
            done + 1,
            settings.repeat,
            seconds[done],
            profile.samples,
            @as(f64, @floatFromInt(once.result.elapsed_ms)) / 1000,
        });
        try w.flush();
    }
    if (done == 0) return;
    try spread_write(w, style, seconds[0..done]);
    try w.print("\n  Saved as the series \"{s}\" ({d} runs) in {s}.\n", .{ label, done, dir });
    try w.writeAll("  Compare it with another series in the app: " ++
        "Saved runs, tick both, Compare.\n");
    try w.flush();
}

const Once = struct { result: client.Result, program: prof.Program };

fn profile_once(ctx: *cli.Context, settings: prof.Settings, exec: []const u8) !Once {
    const argv = try prof.argv_of(ctx, exec, ctx.args);
    const result = client.profile(std.heap.smp_allocator, ctx.allocator, .{
        .program = .{ .argv = argv },
        .metrics = settings.metrics,
        .interval_ms = settings.interval_ms,
        .duration_s = settings.duration_s,
        .from_ms = settings.from_ms,
        .to_ms = settings.to_ms,
    }, null) catch |err| {
        if (prof.launch_failure(err)) |reason| {
            return ctx.fail("cannot launch {s}: {s}", .{ exec, reason });
        }
        const advice = prof.hint(err);
        return ctx.fail("profiling {s} failed: {t}{s}{s}", .{
            exec,
            err,
            if (advice.len > 0) ": " else "",
            advice,
        });
    };
    return .{
        .result = result,
        .program = .{
            .program = std.fs.path.basename(exec),
            .command = try std.mem.join(ctx.allocator, " ", argv),
            .pid = result.pid,
        },
    };
}

/// The mean CPU time of the runs, and how far apart they were.
fn spread_write(w: *std.Io.Writer, style: term.Style, seconds: []const f64) !void {
    var sum: f64 = 0;
    var low = seconds[0];
    var high = seconds[0];
    for (seconds) |value| {
        sum += value;
        low = @min(low, value);
        high = @max(high, value);
    }
    const n: f64 = @floatFromInt(seconds.len);
    const mean = sum / n;
    try w.print("\n  {s}mean{s}  {d:.2} s on the CPU   {s}from{s} {d:.2} {s}to{s} {d:.2} s", .{
        style.on(term.dim),
        style.off(),
        mean,
        style.on(term.dim),
        style.off(),
        low,
        style.on(term.dim),
        style.off(),
        high,
    });
    if (seconds.len < 2 or mean == 0) return w.writeByte('\n');
    var squares: f64 = 0;
    for (seconds) |value| squares += (value - mean) * (value - mean);
    const deviation = @sqrt(squares / (n - 1));
    const percent = 100 * deviation / mean;
    try w.print("   {s}runs differ by{s} ", .{ style.on(term.dim), style.off() });
    if (percent < 0.1) return w.writeAll("under 0.1%\n");
    try w.print("\u{00b1}{d:.1}%\n", .{percent});
}
