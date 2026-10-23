const std = @import("std");
const agent = @import("agent");
const server = @import("server");
const log = @import("log");

const Metric = agent.Metric;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const slog = log.scope("agent_client");

pub const Agent = struct {
    pid: ?i32,
    io: std.Io,
    metrics: std.EnumSet(Metric),
    interval: i64,
    duration: i64,

    pub fn initExec(self: *Agent, allocator: std.mem.Allocator, exec: []const u8, args: []const []const u8) !void {
        slog.info("launching target process", .{
            .exec = exec,
            .args = args.len,
        });
        var child_args = try allocator.alloc([]const u8, args.len + 1);
        defer allocator.free(child_args);

        child_args[0] = exec;
        @memcpy(child_args[1..], args);

        const child = std.process.spawn(self.io, .{ .argv = child_args }) catch |err| {
            slog.err("failed to launch target process", .{
                .exec = exec,
                .cause = err,
            });
            return err;
        };

        self.pid = child.id;

        slog.info("target process started", .{
            .pid = child.id,
        });
    }

    /// Profiles the target until the duration ends or it exits, printing a report per interval.
    pub fn run(self: *Agent, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
        const pid = self.pid orelse return error.NoProcess;

        // Only the cpu metric exists so far.
        if (self.metrics.count() != 1 or !self.metrics.contains(.cpu)) return error.MetricNotImplemented;

        const options = server.CpuOptions{
            .pid = std.math.cast(u32, pid) orelse return error.InvalidPid,
            .interval_ms = std.math.cast(u32, self.interval) orelse return error.InvalidInterval,
            .duration_s = std.math.cast(u32, self.duration) orelse return error.InvalidDuration,
        };

        var printer = Printer{ .out = stdout, .dump = getenv("NUSKU_DUMP") != null };
        slog.info("profiling started", .{ .pid = pid });
        const reason = server.profileCpu(allocator, options, &printer, Printer.onReport) catch |err| {
            slog.err("profiling failed", .{ .pid = pid, .cause = err, .hint = hint(err) });
            return err;
        };
        slog.info("profiling stopped", .{ .pid = pid, .reason = @tagName(reason) });
    }
};

/// How many of the hottest stacks one report shows, and how many frames of each.
const max_stacks = 12;
const max_functions = 10;
const max_frames = 16;

/// Prints each report as text on stdout. A write error (a closed pipe) stops the profile.
const Printer = struct {
    out: *std.Io.Writer,
    /// Also print every function of every window as one tab-separated line, for scripts.
    dump: bool = false,
    window: u64 = 0,

    fn onReport(self: *Printer, report: *const server.CpuReport) !void {
        const w = self.out;
        const Loss = @TypeOf(report.lost);
        try w.print("\npid {d}  window {d} ms  {d} samples in {d} stacks\n", .{
            report.pid,
            report.duration_ns / std.time.ns_per_ms,
            report.samples,
            report.stacks.len,
        });
        const lost = report.lost;
        try w.print("  lost: dropped {d}, map full {d}, held back {d}, bad records {d}\n", .{
            lost.dropped,
            lost.map_full,
            lost.held_back,
            lost.bad_records,
        });
        try printIncomplete(w, lost, report.samples);

        self.window += 1;
        if (self.dump) {
            for (report.functions) |function| {
                var buf: [20]u8 = undefined;
                const label = function.name orelse (std.fmt.bufPrint(&buf, "0x{x}", .{function.address}) catch unreachable);
                try w.print("F\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{
                    self.window,
                    function.self,
                    function.total,
                    if (function.kind == .kernel) "k" else "u",
                    label,
                    function.module orelse "",
                });
            }
        }
        if (report.functions.len > 0) {
            try w.writeAll("\n  top functions\n");
            for (report.functions[0..@min(report.functions.len, max_functions)]) |function| {
                var buf: [20]u8 = undefined;
                const label = function.name orelse (std.fmt.bufPrint(&buf, "0x{x}", .{function.address}) catch unreachable);
                try w.print("    self {d:>5.1}%  total {d:>5.1}%  {s:<40} {s}\n", .{
                    percentOf(function.self, report.samples),
                    percentOf(function.total, report.samples),
                    label,
                    ownerOf(function.kind, function.module),
                });
            }
        }
        for (report.stacks[0..@min(report.stacks.len, max_stacks)]) |stack| {
            const percent = percentOf(stack.samples, report.samples);
            try w.print("\n  {d} samples ({d:.1}%)", .{ stack.samples, percent });
            const reason = Loss.stopName(stack.stop);
            if (stack.stop != 0 and !std.mem.eql(u8, reason, "end")) try w.print("  [cut: {s}]", .{reason});
            try w.writeAll("\n");

            // Frames are root first, so walk backwards to show the innermost, the hot one, first.
            const shown = @min(stack.frames.len, max_frames);
            for (0..shown) |n| {
                try printFrame(w, stack.frames[stack.frames.len - 1 - n]);
            }
            if (stack.frames.len > shown) {
                try w.print("    ... {d} more\n", .{stack.frames.len - shown});
            }
        }
        // Flush so every window shows up as it happens, not when the buffer fills.
        try w.flush();
    }
};

/// One line: the name (or the address if it has none), then who owns it.
fn printFrame(w: *std.Io.Writer, frame: server.Frame) !void {
    var buf: [20]u8 = undefined;
    const label = frame.name orelse (std.fmt.bufPrint(&buf, "0x{x}", .{frame.address}) catch unreachable);
    const owner = ownerOf(frame.kind, frame.module);
    try w.print("    {s:<48} {s}\n", .{ label, owner });
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn percentOf(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

/// The samples whose stack is cut, by the reason the walk stopped. `end` is a complete stack.
fn printIncomplete(w: *std.Io.Writer, lost: anytype, samples: u64) !void {
    const Loss = @TypeOf(lost);
    var cut: u64 = 0;
    for (lost.by_stop, 0..) |n, code| {
        if (n == 0 or std.mem.eql(u8, Loss.stopName(code), "end")) continue;
        cut += n;
    }
    try w.print("  incomplete stacks: {d} of {d} samples ({d:.1}%)", .{ cut, samples, percentOf(cut, samples) });
    if (cut > 0) {
        try w.writeAll(":");
        for (lost.by_stop, 0..) |n, code| {
            if (n == 0 or std.mem.eql(u8, Loss.stopName(code), "end")) continue;
            try w.print(" {s} {d}", .{ Loss.stopName(code), n });
        }
    }
    try w.writeAll("\n");
}

fn ownerOf(kind: server.FrameKind, module: ?[]const u8) []const u8 {
    return switch (kind) {
        .kernel => "kernel",
        .user => if (module) |m| baseName(m) else "unknown",
    };
}

fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.PermissionDenied => "run as root, or grant CAP_BPF, CAP_PERFMON and CAP_SYSLOG",
        error.ProcessNotFound => "no process with that pid",
        error.NotSupported => "the kernel is too old for something the agent needs (Linux 5.3 or newer)",
        error.MetricNotImplemented => "only the cpu metric exists so far",
        else => "",
    };
}

// test "baseName keeps what follows the last slash" {
//     try std.testing.expectEqualStrings("libc.so.6", baseName("/usr/lib/x86_64-linux-gnu/libc.so.6"));
//     try std.testing.expectEqualStrings("yes", baseName("/usr/bin/yes"));
//     try std.testing.expectEqualStrings("app", baseName("app"));
//     try std.testing.expectEqualStrings("", baseName("/usr/lib/"));
// }

// test "printer shows each stack innermost first, with a percentage and short module names" {
//     var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
//     defer aw.deinit();

//     // Root first, as the symbolizer returns them.
//     const frames = [_]server.Frame{
//         .{ .kind = .user, .address = 0x9000 },
//         .{ .kind = .user, .address = 0x1030, .module = "/bin/app" },
//         .{ .kind = .user, .address = 0x1010, .name = "work", .module = "/usr/lib/libwork.so" },
//         .{ .kind = .kernel, .address = 0xffff0001 },
//     };
//     const stacks = [_]server.SymbolizedStack{.{ .samples = 7, .frames = &frames }};
//     const report = server.CpuReport{
//         .pid = 5,
//         .start_unix_ns = 0,
//         .duration_ns = 1_000_000_000,
//         .sample_hz = 99,
//         .samples = 7,
//         .stacks = &stacks,
//     };

//     var printer = Printer{ .out = &aw.writer };
//     try printer.onReport(&report);

//     const text = aw.written();
//     try std.testing.expect(std.mem.indexOf(u8, text, "pid 5  window 1000 ms  7 samples in 1 stacks") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "7 samples (100.0%)") != null);

//     // Innermost first: kernel, then work, then 0x1030, then the root 0x9000.
//     const kernel_at = std.mem.indexOf(u8, text, "0xffff0001") orelse return error.TestUnexpectedResult;
//     const named_at = std.mem.indexOf(u8, text, "work") orelse return error.TestUnexpectedResult;
//     const app_at = std.mem.indexOf(u8, text, "0x1030") orelse return error.TestUnexpectedResult;
//     const root_at = std.mem.indexOf(u8, text, "0x9000") orelse return error.TestUnexpectedResult;
//     try std.testing.expect(kernel_at < named_at and named_at < app_at and app_at < root_at);

//     try std.testing.expect(std.mem.indexOf(u8, text, "libwork.so") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "/usr/lib/") == null); // only the short name
//     try std.testing.expect(std.mem.indexOf(u8, text, "kernel\n") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "unknown\n") != null);
// }

// test "printer cuts long stacks at the innermost frames and says how many it left out" {
//     var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
//     defer aw.deinit();

//     var frames: [20]server.Frame = undefined;
//     for (&frames, 0..) |*frame, i| frame.* = .{ .kind = .user, .address = 0x1000 + i };
//     const stacks = [_]server.SymbolizedStack{.{ .samples = 1, .frames = &frames }};
//     const report = server.CpuReport{
//         .pid = 5,
//         .start_unix_ns = 0,
//         .duration_ns = 1_000_000_000,
//         .sample_hz = 99,
//         .samples = 1,
//         .stacks = &stacks,
//     };

//     var printer = Printer{ .out = &aw.writer };
//     try printer.onReport(&report);

//     const text = aw.written();
//     try std.testing.expect(std.mem.indexOf(u8, text, "... 4 more") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "0x1013 ") != null); // the innermost frame is there
//     try std.testing.expect(std.mem.indexOf(u8, text, "0x1000 ") == null); // the root was cut
// }

// test "printer handles a report without samples" {
//     var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
//     defer aw.deinit();

//     const report = server.CpuReport{
//         .pid = 5,
//         .start_unix_ns = 0,
//         .duration_ns = 1_000_000_000,
//         .sample_hz = 99,
//         .samples = 0,
//         .stacks = &.{},
//     };
//     var printer = Printer{ .out = &aw.writer };
//     try printer.onReport(&report);
//     try std.testing.expect(std.mem.indexOf(u8, aw.written(), "0 samples in 0 stacks") != null);
// }

// test "printer shows the top functions with self and total percentages" {
//     var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
//     defer aw.deinit();

//     const functions = [_]server.FunctionTotal{
//         .{ .kind = .user, .name = "work", .module = "/usr/lib/libwork.so", .address = 0x1000, .self = 6, .total = 9 },
//         .{ .kind = .kernel, .name = null, .module = null, .address = 0xffff0001, .self = 0, .total = 9 },
//     };
//     const report = server.CpuReport{
//         .pid = 5,
//         .start_unix_ns = 0,
//         .duration_ns = 1_000_000_000,
//         .sample_hz = 99,
//         .samples = 10,
//         .stacks = &.{},
//         .functions = &functions,
//     };
//     var printer = Printer{ .out = &aw.writer };
//     try printer.onReport(&report);

//     const text = aw.written();
//     try std.testing.expect(std.mem.indexOf(u8, text, "top functions") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "60.0%") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "90.0%") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "work") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "libwork.so") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "0xffff0001") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "kernel\n") != null);
// }

// test "dump mode prints one machine-readable line per function" {
//     var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
//     defer aw.deinit();

//     const functions = [_]server.FunctionTotal{
//         .{ .kind = .user, .name = "work", .module = "/usr/lib/libwork.so", .address = 0x1000, .self = 6, .total = 9 },
//         .{ .kind = .kernel, .name = null, .module = null, .address = 0xffff0001, .self = 0, .total = 9 },
//     };
//     const report = server.CpuReport{
//         .pid = 5,
//         .start_unix_ns = 0,
//         .duration_ns = 1_000_000_000,
//         .sample_hz = 99,
//         .samples = 10,
//         .stacks = &.{},
//         .functions = &functions,
//     };
//     var printer = Printer{ .out = &aw.writer, .dump = true };
//     try printer.onReport(&report);

//     const text = aw.written();
//     try std.testing.expect(std.mem.indexOf(u8, text, "F\t1\t6\t9\tu\twork\t/usr/lib/libwork.so\n") != null);
//     try std.testing.expect(std.mem.indexOf(u8, text, "F\t1\t0\t9\tk\t0xffff0001\t\n") != null);
// }

// /// The samples whose stack is cut, by the reason the walk stopped. `end` is a complete stack.
// fn printIncomplete(w: *std.Io.Writer, lost: anytype, samples: u64) !void {
//     const Loss = @TypeOf(lost);
//     var cut: u64 = 0;
//     for (lost.by_stop, 0..) |n, code| {
//         if (n == 0 or std.mem.eql(u8, Loss.stopName(code), "end")) continue;
//         cut += n;
//     }
//     try w.print("  incomplete stacks: {d} of {d} samples ({d:.1}%)", .{ cut, samples, percentOf(cut, samples) });
//     if (cut > 0) {
//         try w.writeAll(":");
//         for (lost.by_stop, 0..) |n, code| {
//             if (n == 0 or std.mem.eql(u8, Loss.stopName(code), "end")) continue;
//             try w.print(" {s} {d}", .{ Loss.stopName(code), n });
//         }
//     }
//     try w.writeAll("\n");
// }
