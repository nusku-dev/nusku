const std = @import("std");
const session = @import("core/session.zig");
const cfg = @import("core/config.zig");
const sys = @import("core/sys.zig");
const timer = @import("core/timer.zig");
const pro = @import("profile.zig");
const maps = @import("core/maps.zig");
const buildid = @import("core/buildid.zig");
const procmaps = @import("core/procmaps.zig");
const canc = @import("core/cancel.zig");
const kernel = @import("core/kernel.zig");

pub const Cancel = canc.Cancel;
pub const StopReason = pro.StopReason;
pub const profile = pro.profile;
pub const Options = cfg.Options;
pub const Metric = cfg.Metric;
pub const Report = session.Report;
pub const Region = procmaps.Region;
pub const KernelIdentity = @import("core/kernel.zig").Identity;

const Recorder = struct {
    reports: usize = 0,
    samples: u64 = 0,
    pid: u32 = 0,
    regions: usize = 0,
    user_frames: usize = 0,
    resolved_frames: usize = 0,

    fn onReport(self: *Recorder, report: *const Report) !void {
        self.reports += 1;
        self.pid = report.pid;
        self.regions = @max(self.regions, report.regions.len);
        const cpu = report.cpu orelse return;
        self.samples += cpu.samples;
        for (cpu.stacks) |stack| {
            for (stack.user) |address| {
                self.user_frames += 1;
                if (procmaps.locate(report.regions, address) != null) self.resolved_frames += 1;
            }
        }
    }
};

test "profile: one call streams reports for a process (needs root, skipped otherwise)" {
    // A second thread burns CPU inside our own process, which is the one we profile.
    const burner = try std.Thread.spawn(.{}, burn, .{@as(u64, 1300)});
    defer burner.join();

    var recorder = Recorder{};
    var cancel = try Cancel.init();
    defer cancel.deinit();
    const reason = profile(std.testing.allocator, .{
        .pid = sys.currentPid(),
        .metrics = std.EnumSet(cfg.Metric).initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 1,
    }, &recorder, Recorder.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    std.debug.print("public API: {d} reports, {d} samples, {d} regions, {d} of {d} user frames resolved\n", .{
        recorder.reports, recorder.samples, recorder.regions, recorder.resolved_frames, recorder.user_frames,
    });
    try std.testing.expectEqual(StopReason.duration, reason);
    try std.testing.expect(recorder.reports >= 3 and recorder.reports <= 5);
    try std.testing.expect(recorder.samples >= 20); // about 99 for one busy thread over a second
    try std.testing.expectEqual(sys.currentPid(), recorder.pid);
    try std.testing.expect(recorder.regions > 0);
    try std.testing.expect(recorder.user_frames == 0 or recorder.resolved_frames > 0);
}

fn triggerLater(cancel: *const Cancel, ms: u64) void {
    timer.sleepMs(ms);
    cancel.trigger();
}

fn burn(ms: u64) void {
    const until = timer.nowMs() + ms;
    var x: u64 = 0;
    while (timer.nowMs() < until) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

test "cancel from another thread stops profile (needs root, skipped otherwise)" {
    const burner = try std.Thread.spawn(.{}, burn, .{@as(u64, 1500)});
    defer burner.join();

    var cancel = try Cancel.init();
    defer cancel.deinit();
    const stopper = try std.Thread.spawn(.{}, triggerLater, .{ &cancel, @as(u64, 600) });
    defer stopper.join();

    var recorder = Recorder{};
    const started = timer.nowMs();
    const reason = profile(std.testing.allocator, .{
        .pid = sys.currentPid(),
        .metrics = std.EnumSet(Metric).initOne(.cpu),
        .interval_ms = 200,
        .duration_s = 0,
        .cancel = &cancel,
    }, &recorder, Recorder.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectEqual(StopReason.cancelled, reason);
    try std.testing.expect(recorder.reports >= 2);
    try std.testing.expect(timer.nowMs() - started < 1200);
}

test {
    _ = session;
    _ = pro;
    _ = maps;
    _ = sys;
    _ = buildid;
    _ = procmaps;
    _ = canc;
    _ = timer;
    _ = kernel;
}
