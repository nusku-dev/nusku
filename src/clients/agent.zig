const std = @import("std");
const agent = @import("agent");
const log = @import("log");

const Metric = agent.Metric;

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

        // prof.zig has validated these already; the casts only fail on a programming mistake.
        const options = agent.Options{
            .pid = std.math.cast(u32, pid) orelse return error.InvalidPid,
            .metrics = self.metrics,
            .interval_ms = std.math.cast(u32, self.interval) orelse return error.InvalidInterval,
            .duration_s = std.math.cast(u32, self.duration) orelse return error.InvalidDuration,
        };

        var printer = Printer{ .out = stdout };
        slog.info("agent started", .{ .pid = pid });
        const reason = agent.profile(allocator, options, &printer, Printer.onReport) catch |err| {
            slog.err("profiling failed", .{ .pid = pid, .cause = err, .hint = hint(err) });
            return err;
        };
        slog.info("agent stopped", .{ .pid = pid, .reason = @tagName(reason) });
    }
};

/// Prints each report as text on stdout. A write error (a closed pipe) stops the profile.
const Printer = struct {
    out: *std.Io.Writer,

    fn onReport(self: *Printer, report: *const agent.Report) !void {
        const cpu = report.cpu orelse return;
        const w = self.out;
        try w.print("pid {d}  window {d} ms  cpu {d} samples  {d} stacks  {d} regions\n", .{
            report.pid,
            report.duration_ns / std.time.ns_per_ms,
            cpu.samples,
            cpu.stacks.len,
            report.regions.len,
        });
        for (cpu.stacks[0..@min(cpu.stacks.len, 5)]) |stack| {
            try w.print("  {d:>4}  user", .{stack.samples});
            for (stack.user[0..@min(stack.user.len, 4)]) |address| try printFrame(w, report.regions, address);
            try w.writeAll("  kernel");
            for (stack.kernel[0..@min(stack.kernel.len, 3)]) |address| try w.print(" 0x{x}", .{address});
            try w.writeAll("\n");
        }
        // Flush so every window shows up as it happens, not when the buffer fills.
        try w.flush();
    }
};

///todo: change  A frame as "file+offset" when its address lies in a known region, else the raw address.
fn printFrame(w: *std.Io.Writer, regions: []const agent.Region, address: u64) !void {
    for (regions) |r| {
        if (address >= r.start and address < r.end) {
            const path = if (r.path.len == 0) "[anon]" else r.path;
            return w.print(" {s}+0x{x}", .{ path, address - r.start + r.offset });
        }
    }
    try w.print(" 0x{x}", .{address});
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
