//! End to end: a CPU that comes online during a run is sampled.
//!
//! How: take the last CPU offline, start sampling a busy child, bring the CPU back, pin the
//! child to it, and report. Every sample of a pinned child is taken on that CPU, so samples in
//! the window prove the collector opened an event on the CPU that came back.
//!
//! This changes the machine (a CPU goes offline for a moment), so it is opt-in: it runs only as
//! root, with NUSKU_E2E_HOTPLUG=1 in the environment, and always brings the CPU back.

const std = @import("std");
const testing = std.testing;
const Tables = @import("../../unwind/tables.zig").Tables;
const Collector = @import("../../cpu/collector.zig").Collector;
const cpus = @import("../../os/cpus.zig");
const libbpf = @import("../../bpf/libbpf.zig");
const child_process = @import("../process.zig");
const timer = @import("../../os/timer.zig");

test "a CPU that comes online during a run is sampled (opt-in: NUSKU_E2E_HOTPLUG=1, root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const opt_in = std.c.getenv("NUSKU_E2E_HOTPLUG") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(opt_in), "1")) return error.SkipZigTest;

    const cpu = (try cpu_last_online()) orelse return error.SkipZigTest;
    try child_process.cpu_online_set(cpu, false);
    var cpu_offline = true;
    defer if (cpu_offline) child_process.cpu_online_set(cpu, true) catch {};

    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    const fixture = try testing.allocator.create(struct { tables: Tables, collector: Collector });
    defer testing.allocator.destroy(fixture);
    try fixture.tables.init(testing.allocator);
    defer fixture.tables.deinit(testing.allocator);
    try fixture.collector.init(testing.allocator, &fixture.tables, .{ .sample_hz = 999 });
    defer fixture.collector.deinit(testing.allocator);

    try fixture.collector.start(child);
    try testing.expect(fixture.collector.events[cpu] == null);

    try child_process.cpu_online_set(cpu, true);
    cpu_offline = false;
    try child_process.cpu_pin(child, cpu);

    // The report notices the CPU and opens its event; samples land in the window after it.
    try fixture.collector.generation_advance();
    _ = try fixture.collector.collect();
    try testing.expect(fixture.collector.events[cpu] != null);

    timer.sleep_ms(300);
    try fixture.collector.generation_advance();
    const window = try fixture.collector.collect();
    std.debug.print("hotplug e2e: cpu {d} back online, {d} samples of the pinned child\n", .{
        cpu, window.samples,
    });
    try testing.expect(window.samples >= 50); // About 300 at 999 Hz.
}

/// The highest online CPU other than 0, or null on a machine with one CPU.
fn cpu_last_online() !?u32 {
    const online = try testing.allocator.alloc(bool, try libbpf.cpu_possible_count());
    defer testing.allocator.free(online);
    try cpus.online_read(online);
    var cpu: u32 = @intCast(online.len - 1);
    while (cpu > 0) : (cpu -= 1) {
        if (online[cpu]) return cpu;
    }
    return null;
}
