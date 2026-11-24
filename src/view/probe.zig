//! What `nusku probe` prints: how often a function was called and how long the calls took.

const std = @import("std");
const protocol = @import("shared").protocol;
const term = @import("../term/term.zig");

const Writer = std.Io.Writer;
const Style = term.Style;
const Totals = protocol.probe.Totals;
const Report = protocol.probe.Report;
const buckets = protocol.probe.buckets;

pub const Summary = struct {
    function: []const u8,
    path: []const u8,
    pid: u32,
    elapsed_ms: u64,
    /// Null while it runs.
    reason: ?protocol.RunStop,
    live_hint: []const u8 = "Ctrl-C to stop",
};

pub const Options = struct { color: bool };

/// Returns the number of lines written, so a live view can draw over them.
pub fn write(
    w: *Writer,
    points: []const Report,
    summary: Summary,
    options: Options,
) !usize {
    const style = Style{ .color = options.color };
    const totals = if (points.len > 0) points[points.len - 1].totals else Totals{};
    var lines = try header_write(w, style, summary);
    lines += try numbers_write(w, style, points, totals, summary.elapsed_ms);
    lines += try histogram_write(w, style, &totals);
    lines += try notes_write(w, style, &totals, rate_of(points));
    return lines;
}

fn header_write(w: *Writer, style: Style, summary: Summary) !usize {
    const separator = " \u{00b7} ";
    try w.print("\n  {s}nusku probe{s}  {s}{s}{s} ", .{
        style.on(term.bold_cyan),
        style.off(),
        style.on(term.bold),
        summary.function,
        style.off(),
    });
    try w.print("{s}in {s} [pid {d}]{s}{s}", .{
        style.on(term.dim),
        std.fs.path.basename(summary.path),
        summary.pid,
        separator,
        style.off(),
    });
    try w.print("{d}.{d} s{s}{s}", .{
        summary.elapsed_ms / 1000,
        summary.elapsed_ms % 1000 / 100,
        style.on(term.dim),
        separator,
    });
    const state = if (summary.reason) |reason| switch (reason) {
        .duration => "duration reached",
        .target_exited => "process exited",
        .cancelled => "stopped",
    } else summary.live_hint;
    try w.print("{s}{s}\n\n", .{ state, style.off() });
    return 3;
}

fn numbers_write(
    w: *Writer,
    style: Style,
    points: []const Report,
    totals: Totals,
    elapsed_ms: u64,
) !usize {
    try w.print("    {s}calls{s}      {d}", .{ style.on(term.dim), style.off(), totals.calls });
    if (rate_of(points)) |rate| try w.print("  {s}({d:.1}/s now){s}", .{
        style.on(term.dim),
        rate,
        style.off(),
    });
    try w.writeByte('\n');
    if (totals.timed == 0) {
        try w.print("    {s}no call has returned yet{s}\n", .{ style.on(term.dim), style.off() });
        return 2;
    }
    try w.print("    {s}per call{s}   mean ", .{ style.on(term.dim), style.off() });
    try duration_write(w, totals.total_ns / totals.timed);
    for ([_]struct { []const u8, u64 }{ .{ "p50", 500 }, .{ "p90", 900 }, .{ "p99", 990 } }) |p| {
        try w.print("   {s}{s} \u{2264}{s} ", .{ style.on(term.dim), p[0], style.off() });
        try duration_write(w, percentile(&totals, p[1]));
    }
    try w.print("   {s}max{s} ", .{ style.on(term.dim), style.off() });
    try duration_write(w, totals.max_ns);
    try w.print("\n    {s}inside{s}     ", .{ style.on(term.dim), style.off() });
    try duration_write(w, totals.total_ns);
    if (elapsed_ms > 0) {
        const share = totals.total_ns / std.time.ns_per_ms * 1000 / elapsed_ms;
        try w.print("  {s}{d}.{d}% of the time probed, all threads together{s}", .{
            style.on(term.dim),
            share / 10,
            share % 10,
            style.off(),
        });
    }
    try w.writeByte('\n');
    return 3;
}

fn rate_of(points: []const Report) ?f64 {
    if (points.len < 2) return null;
    const last = points[points.len - 1];
    const before = points[points.len - 2];
    if (last.duration_ns == 0) return null;
    const calls: f64 = @floatFromInt(last.totals.calls -| before.totals.calls);
    return calls * std.time.ns_per_s / @as(f64, @floatFromInt(last.duration_ns));
}

/// A bound on the duration below which `per_mille` of the timed calls fall: the top of its
/// histogram bucket, or the slowest call if that is lower. A bucket spans a factor of two,
/// so the bound is all the histogram can say.
pub fn percentile(totals: *const Totals, per_mille: u64) u64 {
    if (totals.timed == 0) return 0;
    const wanted = (totals.timed * per_mille + 999) / 1000;
    var seen: u64 = 0;
    for (totals.histogram, 0..) |count, bucket| {
        seen += count;
        if (seen >= wanted) return @min(bucket_low(bucket + 1), totals.max_ns);
    }
    return totals.max_ns;
}

fn bucket_low(bucket: usize) u64 {
    if (bucket == 0) return 0;
    return @as(u64, 1) << @intCast(bucket - 1);
}

fn histogram_write(w: *Writer, style: Style, totals: *const Totals) !usize {
    if (totals.timed == 0) return 0;
    var first: ?usize = null;
    var last: usize = 0;
    var largest: u64 = 0;
    for (totals.histogram, 0..) |count, bucket| {
        if (count == 0) continue;
        if (first == null) first = bucket;
        last = bucket;
        largest = @max(largest, count);
    }
    const start = first orelse return 0;
    try w.print("\n  {s}Time per call{s}\n", .{ style.on(term.bold), style.off() });
    for (start..last + 1) |bucket| {
        const count = totals.histogram[bucket];
        var label_buffer: [48]u8 = undefined;
        var label: Writer = .fixed(&label_buffer);
        try duration_write(&label, bucket_low(bucket));
        try label.writeAll(" \u{2013} ");
        try duration_write(&label, bucket_low(bucket + 1));
        const text = label.buffered();
        const columns = std.unicode.utf8CountCodepoints(text) catch text.len;
        try w.writeAll("    ");
        try w.splatByteAll(' ', 19 -| columns);
        try w.print("{s}  ", .{text});
        const share = count * 1000 / largest;
        try w.writeAll(style.heat(count * 1000 / totals.timed, 250));
        try term.bar_write(w, share, 24);
        try w.print("{s}  {d}\n", .{ style.off(), count });
    }
    return 2 + last + 1 - start;
}

/// Below this, a call is mostly the probe's own cost.
const short_call_ns = 10 * std.time.ns_per_us;
/// Above this, the probe slows the program enough to notice.
const busy_calls_per_s = 10_000;

fn notes_write(w: *Writer, style: Style, totals: *const Totals, rate: ?f64) !usize {
    var lines: usize = 0;
    const counted = [_]struct { u64, []const u8 }{
        .{ totals.unmatched, "returns of calls already running when the probe came, not timed" },
        .{ totals.untimed, "calls nested more than 16 deep in a thread, counted but not timed" },
        .{ totals.dropped, "calls not timed: too many threads were inside at once" },
    };
    for (counted) |note| {
        if (note[0] == 0) continue;
        lines += try note_write(w, style, lines);
        try w.print("{s}: {d}\n", .{ note[1], note[0] });
    }
    const mean = if (totals.timed > 0) totals.total_ns / totals.timed else 0;
    if (totals.timed > 0 and mean < short_call_ns) {
        lines += try note_write(w, style, lines);
        try w.writeAll("calls this short are mostly the probe's own cost, " ++
            "about 1\u{2013}4 \u{00b5}s each:\n" ++
            "      compare them between two runs, not as times of their own\n");
        lines += 1;
    }
    if (rate) |per_s| if (per_s > busy_calls_per_s) {
        lines += try note_write(w, style, lines);
        try w.print("{d:.0} calls a second: the probe slows the program noticeably\n", .{per_s});
    };
    return lines;
}

fn note_write(w: *Writer, style: Style, before: usize) !usize {
    const blank: usize = if (before == 0) 1 else 0;
    if (blank == 1) try w.writeByte('\n');
    try w.print("    {s}!{s} ", .{ style.on(term.yellow), style.off() });
    return blank + 1;
}

/// 850 ns, 30.1 µs, 4.2 ms, 1.30 s: three figures at most.
pub fn duration_write(w: *Writer, ns: u64) !void {
    const units = [_]struct { u64, []const u8 }{
        .{ std.time.ns_per_s, "s" },
        .{ std.time.ns_per_ms, "ms" },
        .{ std.time.ns_per_us, "\u{00b5}s" },
    };
    for (units) |unit| {
        if (ns < unit[0]) continue;
        const value = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(unit[0]));
        if (value >= 100) return w.print("{d:.0} {s}", .{ value, unit[1] });
        if (value >= 10) return w.print("{d:.1} {s}", .{ value, unit[1] });
        return w.print("{d:.2} {s}", .{ value, unit[1] });
    }
    return w.print("{d} ns", .{ns});
}

const testing = std.testing;

test "a percentile is the top of its bucket, and never past the slowest call" {
    var totals = Totals{ .timed = 100, .max_ns = 3000 };
    totals.histogram[11] = 90;
    totals.histogram[12] = 10;
    try testing.expectEqual(@as(u64, 2048), percentile(&totals, 500));
    try testing.expectEqual(@as(u64, 2048), percentile(&totals, 900));
    try testing.expectEqual(@as(u64, 3000), percentile(&totals, 990));
    try testing.expectEqual(@as(u64, 0), percentile(&Totals{}, 500));
}

test "durations read in the unit that fits" {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try duration_write(&w, 850);
    try w.writeAll("|");
    try duration_write(&w, 30_100);
    try w.writeAll("|");
    try duration_write(&w, 4_200_000);
    try w.writeAll("|");
    try duration_write(&w, 1_300_000_000);
    try testing.expectEqualStrings("850 ns|30.1 \u{00b5}s|4.20 ms|1.30 s", w.buffered());
}

test "a probe's report: numbers, a histogram, and the notes that apply" {
    var buffer: [4096]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    var totals = Totals{ .calls = 101, .timed = 100, .total_ns = 150_000, .max_ns = 3000 };
    totals.unmatched = 1;
    totals.histogram[11] = 90;
    totals.histogram[12] = 10;
    const points = [_]Report{.{ .start_unix_ns = 0, .duration_ns = 1, .totals = totals }};
    const lines = try write(&w, &points, .{
        .function = "work",
        .path = "/bin/app",
        .pid = 7,
        .elapsed_ms = 2000,
        .reason = .cancelled,
    }, .{ .color = false });
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "work") != null);
    try testing.expect(std.mem.indexOf(u8, text, "in app [pid 7]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "mean 1.50 \u{00b5}s") != null);
    try testing.expect(std.mem.indexOf(u8, text, "already running") != null);
    try testing.expect(std.mem.indexOf(u8, text, "probe's own cost") != null);
    try testing.expectEqual(std.mem.count(u8, text, "\n"), lines);
}
