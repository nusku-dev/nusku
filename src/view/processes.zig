//! The processes of the machine as a table, the busiest first. A process's CPU is a share of
//! one CPU, so busy threads can pass 100%; the header's is the whole machine's, as in `top`.
//!
//!      nusku ps  312 processes · 8 CPUs · CPU 18.4% (user 12.0 system 5.1 iowait 0.3)
//!                · memory 5.3G · every 1.0 s
//!
//!          PID USER         CPU%          MEM  THR  STARTED  COMMAND
//!        41722 ali          98.0% ████▉   812.4M  24     3h12m  /opt/google/chrome/chrome …

const std = @import("std");
const protocol = @import("shared").protocol;
const term = @import("../term.zig");

const Style = term.Style;
const Writer = std.Io.Writer;
const Frame = protocol.ProcessFrame;
const ProcessInfo = protocol.ProcessInfo;

pub const Sort = enum { cpu, mem, pid };

pub const Options = struct {
    /// 0 shows all.
    top: usize = 20,
    /// Of the terminal, to cut commands to. 0: never cut.
    width: usize = 0,
    sort: Sort = .cpu,
    color: bool = false,
    /// The header says how to stop.
    live: bool = false,
};

/// Returns the lines it wrote, for a live view to draw over.
pub fn write(w: *Writer, arena: std.mem.Allocator, frame: *const Frame, options: Options) !usize {
    const style = Style{ .color = options.color };
    const rows = try arena.dupe(ProcessInfo, frame.processes);
    std.mem.sortUnstable(ProcessInfo, rows, options.sort, before);
    const shown = if (options.top == 0) rows else rows[0..@min(options.top, rows.len)];

    try header_write(w, style, frame, options);
    try w.print("\n  {s}{s:>7} {s:<10} {s:>6} {s:<6} {s:>7} {s:>4} {s:>8}  {s}{s}\n", .{
        style.on(term.dim),
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
        try w.print("  {s}\u{2026} {d} more{s}\n", .{ style.on(term.dim), hidden, style.off() });
        lines += 1;
    }
    return lines;
}

fn header_write(w: *Writer, style: Style, frame: *const Frame, options: Options) !void {
    var memory_total: u64 = 0;
    for (frame.processes) |info| memory_total += info.memory_bytes;
    const separator = " \u{00b7} ";
    var memory_buffer: [16]u8 = undefined;
    try w.print("  {s}nusku ps{s}  {d} processes{s}{s}{s}{d} CPUs{s}{s}{s}", .{
        style.on(term.bold_cyan),
        style.off(),
        frame.processes.len,
        style.on(term.dim),
        separator,
        style.off(),
        frame.machine.cpus,
        style.on(term.dim),
        separator,
        style.off(),
    });
    try machine_write(w, style, frame.machine.cpu);
    try w.print("{s}{s}{s}memory {s}", .{
        style.on(term.dim),
        separator,
        style.off(),
        memory_text(&memory_buffer, memory_total),
    });
    const every_ms = frame.interval_ns / std.time.ns_per_ms;
    try w.print("{s}{s}every {d}.{d} s{s}{s}\n", .{
        style.on(term.dim),
        separator,
        every_ms / 1000,
        every_ms % 1000 / 100,
        if (options.live) separator ++ "Ctrl-C to stop" else "",
        style.off(),
    });
}

/// The machine's CPU, and where it went. A dash on the first frame: nothing to measure against.
fn machine_write(w: *Writer, style: Style, cpu: ?protocol.MachineCpu) !void {
    const known = cpu orelse return w.writeAll("CPU -");
    const per_mille: u64 = @intFromFloat(@max(known.busy_percent, 0) * 10);
    try w.print("CPU {s}{d:.1}%{s} {s}(user {d:.1} system {d:.1} iowait {d:.1}){s}", .{
        style.heat(per_mille, 500),
        known.busy_percent,
        style.off(),
        style.on(term.dim),
        known.user_percent,
        known.system_percent,
        known.iowait_percent,
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
    // A kernel thread has no command line: shown by its name in brackets, as by `ps`.
    const kernel_thread = info.command.len == 0;
    try w.print("  {s}{d:>7} {s:<10}{s} ", .{
        if (kernel_thread) style.on(term.dim) else "",
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

    const room = if (width > columns_before_command + 8) width - columns_before_command else 0;
    if (kernel_thread) {
        try w.print("{s}[{s}]{s}\n", .{ style.on(term.dim), info.name, style.off() });
    } else {
        try term.text_cut_write(w, info.command, room);
        try w.writeByte('\n');
    }
}

/// "  " + 7 + 1 + 10 + 1 + 13 + 1 + 7 + 1 + 4 + 1 + 8 + 2.
const columns_before_command = 58;

/// The share, and a bar of 6 columns full at one CPU. Null: started since the last look.
fn cpu_write(w: *Writer, style: Style, percent: ?f32) !void {
    const share = percent orelse {
        try w.print("{s}{s:>6}{s}       ", .{ style.on(term.dim), "-", style.off() });
        return;
    };
    const per_mille: u64 = @intFromFloat(@max(share, 0) * 10);
    try w.print("{s}{d:>5.1}% ", .{ style.heat(per_mille, 500), share });
    try term.bar_write(w, per_mille, 6);
    try w.writeAll(style.off());
}

/// The pid decides between equals, so rows do not swap places between frames.
fn before(sort: Sort, a: ProcessInfo, b: ProcessInfo) bool {
    switch (sort) {
        .cpu => {
            // No CPU yet counts as the least busy.
            const a_cpu = a.cpu_percent orelse -1;
            const b_cpu = b.cpu_percent orelse -1;
            if (a_cpu != b_cpu) return a_cpu > b_cpu;
        },
        .mem => if (a.memory_bytes != b.memory_bytes) return a.memory_bytes > b.memory_bytes,
        .pid => {},
    }
    return a.pid < b.pid;
}

/// K, M or G: at most 7 characters.
fn memory_text(buffer: *[16]u8, bytes: u64) []const u8 {
    const kib = bytes / 1024;
    if (kib < 1024) return std.fmt.bufPrint(buffer, "{d}K", .{kib}) catch unreachable;
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    if (mib < 1024) return std.fmt.bufPrint(buffer, "{d:.1}M", .{mib}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d:.1}G", .{mib / 1024}) catch unreachable;
}

/// "45s", "12m", "3h12m", "12d04h".
fn ago_text(buffer: *[16]u8, now_unix_ns: u64, then_unix_ns: u64) []const u8 {
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
    .machine = .{ .cpus = 8, .cpu = .{
        .busy_percent = 18.4,
        .user_percent = 12,
        .system_percent = 5.1,
        .iowait_percent = 0.3,
        .irq_percent = 1,
        .steal_percent = 0.3,
    } },
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
    const text = try table_test(arena.allocator(), .{});

    try testing.expect(has(text, "nusku ps  3 processes \u{00b7} 8 CPUs \u{00b7} CPU 18.4% " ++
        "(user 12.0 system 5.1 iowait 0.3) \u{00b7} memory"));
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
