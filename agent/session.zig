const std = @import("std");
const ebpf = @import("ebpf");
const Config = @import("config.zig").Config;
const Metric = @import("config.zig").Metric;
const sys = @import("sys.zig");
const oncpu = ebpf.oncpu;

pub const CpuWindow = oncpu.Window; // adjust: the type OnCpu.collect returns

/// The sampling rate. 99 Hz avoids lining up with the kernel's own 100 Hz timer tick.
const sample_hz = 99;

const SIGINT = 2;
const SIGTERM = 15;

/// The longest duration whose milliseconds fit in the timer's 32-bit argument (about 49 days).
const max_duration_s = std.math.maxInt(u32) / 1000;

pub const Report = struct {
    /// Monotonic milliseconds when the report was taken.
    timestamp_ms: u64,
    cpu: ?oncpu.Window = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    started: bool = false,
    cpu: ?oncpu.OnCpu = null,

    pub fn init(allocator: std.mem.Allocator, metrics: std.EnumSet(Metric)) !Session {
        if (metrics.count() == 0) return error.NoMetrics;
        var self = Session{ .allocator = allocator };
        errdefer self.deinit();

        if (metrics.contains(.cpu)) {
            self.cpu = try oncpu.OnCpu.init(allocator);
        } else {
            return error.MetricNotImplemented;
        }

        return self;
    }
    pub fn deinit(self: *Session) void {
        if (self.cpu) |*cpu| {
            cpu.deinit();
            self.cpu = null;
        }
    }
    pub fn start(self: *Session, pid: u32) !void {
        if (self.started) return error.AlreadyStarted;
        if (!sys.isValidPid(pid)) return error.InvalidPid;
        if (self.cpu) |*cpu| try cpu.start(pid, sample_hz);
        self.started = true;
    }

    pub fn report(self: *Session, arena: std.mem.Allocator) !Report {
        if (!self.started) return error.NotStarted;

        var result = Report{ .timestamp_ms = sys.nowMs() };
        if (self.cpu) |*cpu| result.cpu = try cpu.collect(arena);
        return result;
    }
};

const Set = std.EnumSet(Metric);

fn burn(ms: u64) void {
    const until = sys.nowMs() + ms;
    var x: u64 = 0;
    while (sys.nowMs() < until) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

test "session samples this process and reports one window per call (needs root, skipped otherwise)" {
    var session = Session.init(std.testing.allocator, Set.initOne(.cpu)) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer session.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Misuse is a plain error, not an assert, so it can be tested.
    try std.testing.expectError(error.NotStarted, session.report(arena.allocator()));
    try std.testing.expectError(error.InvalidPid, session.start(0));
    try session.start(sys.currentPid());
    try std.testing.expectError(error.AlreadyStarted, session.start(sys.currentPid()));

    burn(300);
    const first = try session.report(arena.allocator());
    burn(300);
    const second = try session.report(arena.allocator());

    try std.testing.expect(first.cpu != null and second.cpu != null);
    try std.testing.expect(second.timestamp_ms >= first.timestamp_ms + 250);
    // 300 ms at 99 Hz is about 30 samples per window.
    try std.testing.expect(first.cpu.?.samples >= 5);
    try std.testing.expect(second.cpu.?.samples >= 5);

    std.debug.print("session: {d} and {d} samples, {d} ms apart\n", .{
        first.cpu.?.samples, second.cpu.?.samples, second.timestamp_ms - first.timestamp_ms,
    });
}
