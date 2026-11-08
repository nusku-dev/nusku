//! The processes of the machine as a table, for a terminal: a summary line, then one row per
//! process, the busiest first.
//!
//!      nusku ps  312 processes · 8 CPUs · CPU 143.2% · memory 5.3G · every 1.0 s
//!
//!          PID USER         CPU%          MEM  THR  STARTED  COMMAND
//!        41722 ali          98.0% ████▉   812.4M  24     3h12m  /opt/google/chrome/chrome …
//!          917 root          2.0% ▏         9.1M   1   12d04h  [kworker/3:1]
//!
//! CPU is a share of one CPU, so a process with busy threads can pass 100%. `write` returns
//! how many lines it drew, so a live view can go back up over them and draw the next frame.

const std = @import("std");
const server = @import("server");

const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Frame = server.processes.Frame;
const ProcessInfo = server.processes.ProcessInfo;

pub const Sort = enum { cpu, mem, pid };

pub const Options = struct {
    /// Rows, the busiest first; 0 shows all.
    top: usize = 20,
    /// Columns of the terminal: a command is cut to fit. 0: never cut.
    width: usize = 0,
    sort: Sort = .cpu,
    color: bool = false,
    /// The frames keep coming: the header says how to stop.
    live: bool = false,
    cpus: usize = 1,
};

/// The table of `frame`. Returns how many lines it wrote.
pub fn write(w: *Writer, arena: std.mem.Allocator, frame: *const Frame, options: Options) !usize {
    const style = Style{ .color = options.color };
    const rows = try arena.dupe(ProcessInfo, frame.processes);
    std.mem.sortUnstable(ProcessInfo, rows, options.sort, before);
    const shown = if (options.top == 0) rows else rows[0..@min(options.top, rows.len)];

    try header_write(w, style, frame, options);
    try w.print("\n  {s}{s:>7} {s:<10} {s:>6} {s:<6} {s:>7} {s:>4} {s:>8}  {s}{s}\n", .{
        style.on(dim),
        "PID",
        "USER",
        "CPU%",
        "",
        "MEM",
        "THR",
        "STARTED",
        "COMMAND",
        style.off(),
    });
    for (shown) |*info| try row_write(w, style, frame, info, options.width);
    const hidden = rows.len - shown.len;
    var lines = 3 + shown.len;
    if (hidden > 0) {
        try w.print("  {s}\u{2026} {d} more{s}\n", .{ style.on(dim), hidden, style.off() });
        lines += 1;
    }
    return lines;
}

fn header_write(w: *Writer, style: Style, frame: *const Frame, options: Options) !void {
    var cpu_total: f64 = 0;
    var memory_total: u64 = 0;
    for (frame.processes) |info| {
        cpu_total += info.cpu_percent orelse 0;
        memory_total += info.memory_bytes;
    }
    const separator = " \u{00b7} ";
    var memory_buffer: [16]u8 = undefined;
    try w.print("  {s}nusku ps{s}  {d} processes{s}{s}{s}{d} CPUs", .{
        style.on(bold_cyan),
        style.off(),
        frame.processes.len,
        style.on(dim),
        separator,
        style.off(),
        options.cpus,
    });
    try w.print("{s}{s}{s}CPU {d:.1}%{s}{s}{s}memory {s}", .{
        style.on(dim),
        separator,
        style.off(),
        cpu_total,
        style.on(dim),
        separator,
        style.off(),
        memory_text(&memory_buffer, memory_total),
    });
    const every_ms = frame.interval_ns / std.time.ns_per_ms;
    try w.print("{s}{s}every {d}.{d} s{s}{s}\n", .{
        style.on(dim),
        separator,
        every_ms / 1000,
        every_ms % 1000 / 100,
        if (options.live) separator ++ "Ctrl-C to stop" else "",
        style.off(),
    });
}

fn row_write(
    w: *Writer,
    style: Style,
    frame: *const Frame,
    info: *const ProcessInfo,
    width: usize,
) !void {
    // A kernel thread has no command line: shown by its name in brackets, as `ps` does.
    const kernel_thread = info.command.len == 0;
    try w.print("  {s}{d:>7} {s:<10}{s} ", .{
        if (kernel_thread) style.on(dim) else "",
        info.pid,
        info.user[0..@min(info.user.len, 10)],
        if (kernel_thread) style.off() else "",
    });
    try cpu_write(w, style, info.cpu_percent);

    var memory_buffer: [16]u8 = undefined;
    var started_buffer: [16]u8 = undefined;
    try w.print(" {s:>7} {d:>4} {s:>8}  ", .{
        memory_text(&memory_buffer, info.memory_bytes),
        info.threads,
        ago_text(&started_buffer, frame.unix_ns, info.started_unix_ns),
    });

    // What is left of the line for the command: the columns before it take 58.
    const room = if (width > columns_before_command + 8) width - columns_before_command else 0;
    if (kernel_thread) {
        try w.print("{s}[{s}]{s}\n", .{ style.on(dim), info.name, style.off() });
    } else {
        try text_cut_write(w, info.command, room);
        try w.writeByte('\n');
    }
}

/// "  " + 7 + 1 + 10 + 1 + 13 + 1 + 7 + 1 + 4 + 1 + 8 + 2.
const columns_before_command = 58;

/// The share, and a bar of 6 columns where a full one is a whole CPU. Null: the process
/// started since the look before, so it has no CPU yet.
fn cpu_write(w: *Writer, style: Style, percent: ?f32) !void {
    const share = percent orelse {
        try w.print("{s}{s:>6}{s}       ", .{ style.on(dim), "-", style.off() });
        return;
    };
    try w.print("{s}{d:>5.1}% ", .{ style.heat(share), share });
    const eighths = [_][]const u8{
        "",
        "\u{258f}",
        "\u{258e}",
        "\u{258d}",
        "\u{258c}",
        "\u{258b}",
        "\u{258a}",
        "\u{2589}",
    };
    const columns = 6;
    const clamped: f32 = @min(@max(share, 0), 100);
    const units: usize = @intFromFloat(clamped * columns * 8 / 100);
    const full = units / 8;
    for (0..full) |_| try w.writeAll("\u{2588}");
    try w.writeAll(eighths[units % 8]);
    try w.splatByteAll(' ', columns - full - @intFromBool(units % 8 != 0));
    try w.writeAll(style.off());
}

/// `text`, cut to `room` columns with "…" when longer. 0: not cut.
fn text_cut_write(w: *Writer, text: []const u8, room: usize) !void {
    if (room == 0 or text.len <= room) return w.writeAll(text);
    try w.writeAll(text[0 .. room - 1]);
    try w.writeAll("\u{2026}");
}

/// The order of the rows. The pid decides between equals, so rows do not swap places from one
/// frame to the next.
fn before(sort: Sort, a: ProcessInfo, b: ProcessInfo) bool {
    switch (sort) {
        .cpu => {
            // No CPU yet (a process that just started) counts as the least busy.
            const a_cpu = a.cpu_percent orelse -1;
            const b_cpu = b.cpu_percent orelse -1;
            if (a_cpu != b_cpu) return a_cpu > b_cpu;
        },
        .mem => if (a.memory_bytes != b.memory_bytes) return a.memory_bytes > b.memory_bytes,
        .pid => {},
    }
    return a.pid < b.pid;
}

/// Bytes as K, M or G: at most 7 characters.
pub fn memory_text(buffer: *[16]u8, bytes: u64) []const u8 {
    const kib = bytes / 1024;
    if (kib < 1024) return std.fmt.bufPrint(buffer, "{d}K", .{kib}) catch unreachable;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    if (mib < 1024) return std.fmt.bufPrint(buffer, "{d:.1}M", .{mib}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d:.1}G", .{mib / 1024}) catch unreachable;
}

/// How long ago `then_unix_ns` was, seen at `now_unix_ns`: "45s", "12m", "3h12m", "12d04h".
pub fn ago_text(buffer: *[16]u8, now_unix_ns: u64, then_unix_ns: u64) []const u8 {
    const seconds = (now_unix_ns -| then_unix_ns) / std.time.ns_per_s;
    const minutes = seconds / 60;
    const hours = minutes / 60;
    const days = hours / 24;
    return (if (minutes == 0)
        std.fmt.bufPrint(buffer, "{d}s", .{seconds})
    else if (hours == 0)
        std.fmt.bufPrint(buffer, "{d}m", .{minutes})
    else if (days == 0)
        std.fmt.bufPrint(buffer, "{d}h{d:0>2}m", .{ hours, minutes % 60 })
    else
        std.fmt.bufPrint(buffer, "{d}d{d:0>2}h", .{ days, hours % 24 })) catch unreachable;
}

// ------------------------------------------------------------------------------------- style

const bold_cyan = "\x1b[1;36m";
const dim = "\x1b[2m";
const yellow = "\x1b[33m";
const red = "\x1b[1;31m";
const reset = "\x1b[0m";

const Style = struct {
    color: bool,

    fn on(style: Style, code: []const u8) []const u8 {
        return if (style.color) code else "";
    }

    fn off(style: Style) []const u8 {
        return style.on(reset);
    }

    /// Half a CPU or more is red, a tenth yellow, under one percent dim.
    fn heat(style: Style, percent: f32) []const u8 {
        if (percent >= 50) return style.on(red);
        if (percent >= 10) return style.on(yellow);
        if (percent < 1) return style.on(dim);
        return "";
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

const second: u64 = std.time.ns_per_s;

const processes_test = [_]ProcessInfo{
    .{
        .pid = 917,
        .name = "kworker/3:1",
        .user = "root",
        .command = "",
        .threads = 1,
        .cpu_percent = 0.5,
        .memory_bytes = 0,
        .started_unix_ns = 1000 * second,
    },
    .{
        .pid = 41722,
        .name = "chrome",
        .user = "ali",
        .command = "/opt/google/chrome/chrome --type=renderer --lang=en-US",
        .threads = 24,
        .cpu_percent = 98.0,
        .memory_bytes = 812 * 1024 * 1024,
        .started_unix_ns = 4000 * second,
    },
    .{
        .pid = 5,
        .name = "new",
        .user = "ali",
        .command = "/bin/new",
        .threads = 1,
        .cpu_percent = null,
        .memory_bytes = 4096,
        .started_unix_ns = 5000 * second,
    },
};

const frame_test = Frame{
    .unix_ns = 5040 * second,
    .interval_ns = second,
    .processes = &processes_test,
};

fn table_test(arena: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const lines = try write(&out.writer, arena, &frame_test, options);
    try testing.expectEqual(std.mem.count(u8, out.written(), "\n"), lines);
    return out.written();
}

fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "the header sums the machine; rows go busiest first, a new process last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try table_test(arena.allocator(), .{ .cpus = 8 });

    try testing.expect(has(text, "nusku ps  3 processes \u{00b7} 8 CPUs \u{00b7} CPU 98.5%"));
    try testing.expect(has(text, "every 1.0 s\n"));
    try testing.expect(!has(text, "Ctrl-C")); // Not live.
    const chrome = std.mem.indexOf(u8, text, "41722").?;
    const kworker = std.mem.indexOf(u8, text, "  917").?;
    const new = std.mem.indexOf(u8, text, "      5 ").?;
    try testing.expect(chrome < kworker and kworker < new);
    // 98% of a CPU: a bar of almost six blocks. A kernel thread by its name in brackets.
    try testing.expect(has(text, " 98.0% " ++ "\u{2588}" ** 5 ++ "\u{2589}"));
    try testing.expect(has(text, "[kworker/3:1]"));
    try testing.expect(has(text, "812.0M"));
    try testing.expect(has(text, "17m")); // Started 1040 s before the look.
}

test "the command is cut to the terminal, the rest counted, sorted as asked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = try table_test(arena.allocator(), .{
        .top = 2,
        .width = columns_before_command + 20,
        .sort = .mem,
        .live = true,
    });
    try testing.expect(has(text, "/opt/google/chrome/\u{2026}\n"));
    try testing.expect(has(text, "\u{2026} 1 more\n"));
    try testing.expect(has(text, "Ctrl-C to stop"));
    // By memory: chrome, then the new one (4K), and the kernel thread (0) is hidden.
    try testing.expect(!has(text, "kworker"));
    try testing.expect(!has(text, "\x1b[")); // No colors unless asked.
}
