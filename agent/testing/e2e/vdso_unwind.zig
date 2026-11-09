//! End to end: a child that calls the vDSO's clock_gettime in a loop is profiled with its
//! callers. Its stacks in the vDSO must climb out into its own code, to the outermost frame.
//! Needs root.

const std = @import("std");
const testing = std.testing;
const Target = @import("../../target.zig").Target;
const Ebpf = @import("../../ebpf.zig").Ebpf;
const vdso = @import("../../target/vdso.zig");
const timer = @import("../../os.zig").timer;
const child_process = @import("../process.zig");

const Region = @import("../../target/regions.zig").Region;

test "stacks inside the vDSO keep their callers (needs root, skipped otherwise)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    // Skipped when the vDSO has no clock_gettime to call.
    const clock_gettime = (try child_process.vdso_clock_gettime(testing.allocator)) orelse
        return error.SkipZigTest;
    const child = try child_process.clock_reader_spawn(3000, clock_gettime);
    defer child_process.child_reap(child);

    var target = try Target.init(testing.allocator, child);
    defer target.deinit(testing.allocator);
    const ebpf = try testing.allocator.create(Ebpf);
    defer testing.allocator.destroy(ebpf);
    try ebpf.init(testing.allocator, &target, .{ .metrics = .initOne(.cpu) });
    defer ebpf.deinit(testing.allocator);

    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        timer.sleep_ms(100);
        try ebpf.tick(testing.allocator, &target);
    }
    const windows = try ebpf.collect(testing.allocator, &target);
    const window = windows.cpu orelse return error.TestUnexpectedResult;
    try testing.expect(window.samples >= 20);
    try testing.expectEqual(@as(u32, 0), windows.unwind.unavailable.get(.vdso_unknown));

    const vdso_region = region_find(target.regions, vdso.path) orelse
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
