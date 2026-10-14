const std = @import("std");
const Session = @import("session.zig").Session;
const cfg = @import("config.zig");
const sig = @import("sig.zig");
const sys = @import("sys.zig");
const timer = @import("times.zig");
const p = @import("poll.zig");

const Config = cfg.Config;
const Matreic = cfg.Metric;

pub const StopReason = enum { duration, target_exited, signal };

pub const Driver = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    config: Config,
    timer_fd: c_int,
    pid_fd: c_int,
    signal_fd: c_int,
    /// The signal mask from before `init`, put back by `deinit`.
    old_mask: sig.SigSet,

    /// Counters, mostly for tests.
    reports: usize = 0,
    total_samples: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, session: *Session, config: Config) !Driver {
        if (!sys.isValidPid(config.pid)) return error.InvalidPid;
        if (config.interval_ms == 0) return error.InvalidInterval;

        const pid_fd = try sys.pidfdSyscall(config.pid);
        errdefer sys.fdClose(pid_fd);

        const stop_sig = try sig.makeStopSignalSet();

        var old_mask: sig.SigSet = undefined;
        try sig.setSignalMask(.block, &stop_sig, &old_mask);
        errdefer sig.setSignalMask(.set_mask, &old_mask, null) catch {};

        const signal_fd = try sig.createSignalFd(&stop_sig);
        errdefer sys.fdClose(signal_fd);

        const timer_fd = try sig.createTimerFd();
        errdefer sys.fdClose(timer_fd);

        return .{
            .allocator = allocator,
            .session = session,
            .config = config,
            .timer_fd = timer_fd,
            .pid_fd = pid_fd,
            .signal_fd = signal_fd,
            .old_mask = old_mask,
        };
    }

    pub fn run(self: *Driver) !StopReason {
        try self.session.start(self.config.pid);
        try timer.ConfigTimer(self.config.interval_ms, self.timer_fd);

        const started = timer.nowMs();

        const deadline: ?u64 =
            if (self.config.duration_s == 0)
                null
            else
                started + @as(u64, self.config.duration_s) * 1000;

        var poll = p.Poll.init(self.timer_fd, self.pid_fd, self.signal_fd);

        while (true) {
            const timeout: c_int = if (deadline) |d| blk: {
                const now = timer.nowMs();
                break :blk if (now >= d) 0 else @intCast(@min(d - now, std.math.maxInt(c_int)));
            } else -1;

            const event = poll.wait(timeout) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return err,
            };
            var reported = false;
            if (event.timer) {
                var expirations: u64 = undefined;
                try p.readEvents(self.timer_fd, std.mem.asBytes(&expirations));
                try self.report();
                reported = true;
            }

            const finished = if (deadline) |d| timer.nowMs() >= d else false;
            if (event.exited or event.signalled or finished) {
                if (event.signalled) {
                    var info: [128]u8 = undefined;
                    try p.readEvents(self.signal_fd, &info);
                }
                if (!reported) try self.report(); // the last, partial window
                const stop_reason: StopReason = if (event.signalled) .signal else if (event.exited) .target_exited else .duration;
                return stop_reason;
            }
        }
    }

    fn report(self: *Driver) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const result = try self.session.report(arena.allocator());

        self.reports += 1;
        if (result.cpu) |cpu| self.total_samples += cpu.samples;
    }

    pub fn deinit(self: *Driver) void {
        sys.fdClose(self.timer_fd);
        sys.fdClose(self.signal_fd);
        sys.fdClose(self.pid_fd);
        sig.setSignalMask(.set_mask, &self.old_mask, null) catch {};
        self.* = undefined;
    }
};

const Set = std.EnumSet(cfg.Metric);

test "init rejects bad arguments before touching anything" {
    var session: Session = undefined; // never used: init fails first
    const me = sys.currentPid();
    try std.testing.expectError(error.InvalidPid, Driver.init(std.testing.allocator, &session, .{ .pid = 0, .interval_ms = 100, .duration_s = 0 }));
    try std.testing.expectError(error.InvalidInterval, Driver.init(std.testing.allocator, &session, .{ .pid = me, .interval_ms = 0, .duration_s = 0 }));
    try std.testing.expectError(error.ProcessNotFound, Driver.init(std.testing.allocator, &session, .{ .pid = std.math.maxInt(i32), .interval_ms = 100, .duration_s = 0 }));
}

test "stops when the target exits and reports its CPU use (needs root, skipped otherwise)" {
    var session = Session.init(std.testing.allocator, Set.initOne(.cpu)) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer session.deinit();

    const child = try sys.spawnBurner(700);
    defer sys.reap(child);

    var driver = try Driver.init(std.testing.allocator, &session, .{ .pid = child, .interval_ms = 200, .duration_s = 0 });
    defer driver.deinit();

    const started = timer.nowMs();
    _ = try driver.run();
    const elapsed = timer.nowMs() - started;

    std.debug.print("driver: {d} reports, {d} samples, {d} ms\n", .{ driver.reports, driver.total_samples, elapsed });
    try std.testing.expect(elapsed < 1500);
    try std.testing.expect(driver.reports >= 3); // ticks at 200, 400, 600 ms, then the exit
    try std.testing.expect(driver.total_samples >= 20); // about 69 for 700 ms at 99 Hz
}

test "stops at the duration while the target keeps running (needs root, skipped otherwise)" {
    var session = Session.init(std.testing.allocator, Set.initOne(.cpu)) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer session.deinit();

    const child = try sys.spawnBurner(5000);
    defer sys.reap(child);

    var driver = try Driver.init(std.testing.allocator, &session, .{ .pid = child, .interval_ms = 300, .duration_s = 1 });
    defer driver.deinit();

    const started = timer.nowMs();
    _ = try driver.run();
    const elapsed = timer.nowMs() - started;

    std.debug.print("driver: {d} reports, {d} samples, {d} ms\n", .{ driver.reports, driver.total_samples, elapsed });
    try std.testing.expect(elapsed >= 1000 and elapsed < 1500);
    try std.testing.expect(driver.reports >= 3 and driver.reports <= 5);
    try std.testing.expect(driver.total_samples >= 40);
}

fn expectCleanStop(s: c_int) !void {
    var session = Session.init(std.testing.allocator, Set.initOne(.cpu)) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer session.deinit();

    const target = try sys.spawnBurner(5000);
    defer sys.reap(target);

    var driver = try Driver.init(std.testing.allocator, &session, .{ .pid = target, .interval_ms = 300, .duration_s = 0 });
    defer driver.deinit();

    // Fork the sender only now: the signals are blocked, so even one that arrives early
    // simply waits for the driver to read it.
    const sender = try sys.spawnSignaller(500, s);
    defer sys.reap(sender);

    const started = timer.nowMs();
    const stop_reason = try driver.run();
    const elapsed = timer.nowMs() - started;

    std.debug.print("driver: {d} reports, {d} samples, {d} ms, stopped by {s}\n", .{
        driver.reports, driver.total_samples, elapsed, @tagName(stop_reason),
    });
    try std.testing.expectEqual(StopReason.signal, stop_reason);
    try std.testing.expect(elapsed >= 400 and elapsed < 1200);
    try std.testing.expect(driver.reports >= 2); // the tick at 300 ms and the final window
}
