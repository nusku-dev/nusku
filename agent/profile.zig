const std = @import("std");
const s = @import("core/session.zig");
const c = @import("core/config.zig");
const d = @import("core/driver.zig");
const sys = @import("core/sys.zig");

const Session = s.Session;
const StopReason = d.StopReason;
const Driver = d.Driver;

/// Profiles one process from start to finish and returns why it stopped.
/// Needs root, or CAP_BPF and CAP_PERFMON.
pub fn profile(allocator: std.mem.Allocator, options: c.Options) !StopReason {
    var session = try Session.init(allocator, options.metrics);
    defer session.deinit();

    var driver = try Driver.init(allocator, &session, .{
        .pid = options.pid,
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
    });
    defer driver.deinit();

    return try driver.run();
}

const Set = std.EnumSet(c.Metric);

test "profile runs a whole session and says why it stopped (needs root, skipped otherwise)" {
    const child = try sys.spawnBurner(5000);
    defer sys.reap(child);

    const reason = profile(std.testing.allocator, .{
        .pid = child,
        .metrics = Set.initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 1,
    }) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(StopReason.duration, reason);
}
