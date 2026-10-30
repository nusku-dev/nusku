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
        _ = allocator;
        _ = stdout;

        // prof.zig has validated these already; the casts only fail on a programming mistake.
        slog.info("agent started", .{ .pid = pid });
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
