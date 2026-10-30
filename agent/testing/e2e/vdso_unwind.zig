//! End to end: a process that spends its time reading the clock must still be profiled with
//! its callers.
//!
//! How: fork a child whose hot loop calls the vDSO's clock_gettime directly. Profile it
//! for real (BPF program, perf events, unwind tables), and look at the stacks whose innermost
//! frame is in the vDSO. Each must climb out of the vDSO into the child's own code and reach
//! the outermost frame. Without the vDSO's table they stop at the first frame, or skip the
//! caller.
//!
//! Test-only, like everything under testing/. Needs root, and is skipped otherwise.

const std = @import("std");
const testing = std.testing;
const session_file = @import("../../session.zig");
const vdso = @import("../../target/vdso.zig");
const timer = @import("../../os/timer.zig");
const child_process = @import("../process.zig");

const Session = session_file.Session;
const Region = @import("../../target/regions.zig").Region;

test "stacks inside the vDSO keep their callers (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    // Skipped when the vDSO has no clock_gettime to call.
    const clock_gettime = (try child_process.vdso_clock_gettime(testing.allocator)) orelse
        return error.SkipZigTest;
    const child = try child_process.clock_reader_spawn(3000, clock_gettime);
    defer child_process.child_reap(child);

    const session = try testing.allocator.create(Session);
    defer testing.allocator.destroy(session);
    try session.init(testing.allocator, .{
        .pid = child,
        .metrics = std.EnumSet(session_file.Metric).initOne(.cpu),
    });
    defer session.deinit(testing.allocator);

    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        timer.sleep_ms(100);
        try session.tick();
    }
    const report = try session.report(testing.allocator);
    const window = report.cpu orelse return error.TestUnexpectedResult;
    try testing.expect(window.samples >= 20);
    try testing.expectEqual(@as(u32, 0), report.unwind.unavailable.get(.vdso_unknown));

    const vdso_region = region_find(report.regions, vdso.path) orelse
        return error.TestUnexpectedResult;

    var vdso_samples: u64 = 0;
    var vdso_samples_complete: u64 = 0;
    for (window.stacks) |stack| {
        if (stack.user.len == 0) continue;
        if (!region_contains(vdso_region, stack.user[0])) continue;
        vdso_samples += stack.samples;

        // Complete, and the caller of the vDSO frame is the child's own code, not the vDSO.
        if (stack.stop != .end) continue;
        if (stack.user.len < 3) continue;
        if (region_contains(vdso_region, stack.user[1])) continue;
        vdso_samples_complete += stack.samples;
    }
    std.debug.print("vdso e2e: {d} samples, {d} in the vDSO, {d} of those complete\n", .{
        window.samples, vdso_samples, vdso_samples_complete,
    });

    // The child does nothing but call the vDSO, so most samples are in it...
    try testing.expect(vdso_samples * 2 >= window.samples);
    // ...and nearly all of those must walk out of it to the outermost frame.
    try testing.expect(vdso_samples_complete * 10 >= vdso_samples * 9);
}

fn region_find(regions: []const Region, path: []const u8) ?*const Region {
    for (regions) |*region| {
        if (std.mem.eql(u8, region.path, path)) return region;
    }
    return null;
}

fn region_contains(region: *const Region, address: u64) bool {
    return address >= region.start and address < region.end;
}
