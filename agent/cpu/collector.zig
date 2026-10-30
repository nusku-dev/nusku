//! The CPU metric: samples the target's stacks on every CPU, and hands out one window of
//! samples per report.
//!
//! Control plane and data plane. Samples are taken and counted in the kernel, at the sampling
//! rate, and never cross into the agent one by one. The agent runs at its own pace: a tick reads
//! the ring buffer, and a report advances the generation and drains one window of counts in two
//! system calls. Every buffer is allocated at init, so a report allocates nothing.
//!
//! A report is two calls, `generation_advance` and then `collect`. The work the caller does in
//! between (reading the target's mappings) gives the samples that read the old generation time
//! to finish before its counts are drained.

const std = @import("std");
const assert = std.debug.assert;
const cpu_wire = @import("../bpf/kernel/shared/cpu_wire.zig");
const RingBuffer = @import("../bpf/ring_buffer.zig").RingBuffer;
const PerfEvent = @import("../os/perf_event.zig").PerfEvent;
const cpus = @import("../os/cpus.zig");
const Tables = @import("../unwind/tables.zig").Tables;
const frame_cache = @import("frame_cache.zig");
const sampler_file = @import("sampler.zig");
const window = @import("window.zig");

const FrameCache = frame_cache.FrameCache;
const Sampler = sampler_file.Sampler;
const Counters = sampler_file.Counters;
const CountKey = cpu_wire.CountKey;

const log = std.log.scoped(.cpu);

pub const Window = window.Window;
pub const Stack = window.Stack;
pub const Loss = window.Loss;
pub const StopReason = window.StopReason;

/// Frames kept per cache epoch. Sketch: a busy service has a few hundred distinct stacks per
/// window, of about 48 frames: 20k frames. 512k frames (4 MiB per epoch) leaves room for 10k
/// distinct stacks of 48 frames. Untouched pages cost no memory.
const cache_frames_max = 512 * 1024;

const Records = RingBuffer(FrameCache, FrameCache.record_add);

pub const Options = struct {
    /// Samples per second on each CPU. 99, not 100, so sampling does not run in lockstep with
    /// work that runs on a 10 ms timer and always land in it, or always miss it.
    sample_hz: u32 = 99,
};

pub const Collector = struct {
    sampler: Sampler,
    cache: FrameCache,
    records: Records,
    /// One slot per possible CPU: the event sampling it, or null while the CPU is offline.
    events: []?PerfEvent,
    /// Which CPUs were online at the last `cpus_sync`. One per possible CPU, like `events`.
    cpus_online: []bool,

    sample_hz: u32,
    /// The target: 0 before `start`.
    tgid: u32,
    /// What the kernel stamps on every count. Advanced at every report.
    generation: u32,
    /// Set by `generation_advance`, cleared by `collect`: the two alternate.
    generation_advanced: bool,

    /// Where the drained counts land, and the window's stacks: `counts_max` each.
    count_keys: []CountKey,
    count_values: []u64,
    stacks: []window.Stack,
    /// The counters at the previous report, to turn the run's totals into a window's.
    counters_previous: Counters,
    records_malformed_previous: u64,

    /// The collector must stay at its address until `deinit`: the ring reader points into it.
    pub fn init(
        collector: *Collector,
        gpa: std.mem.Allocator,
        tables: *const Tables,
        options: Options,
    ) !void {
        assert(options.sample_hz > 0);
        collector.* = .{
            .sampler = undefined,
            .cache = undefined,
            .records = undefined,
            .events = &.{},
            .cpus_online = &.{},
            .sample_hz = options.sample_hz,
            .tgid = 0,
            .generation = 0,
            .generation_advanced = false,
            .count_keys = &.{},
            .count_values = &.{},
            .stacks = &.{},
            .counters_previous = .{},
            .records_malformed_previous = 0,
        };

        try collector.sampler.init(gpa, tables);
        errdefer collector.sampler.deinit(gpa);

        try collector.cache.init(gpa, .{
            .stacks_max = cpu_wire.counts_max,
            .frames_max = cache_frames_max,
        });
        errdefer collector.cache.deinit(gpa);

        collector.records = try Records.init(collector.sampler.records_fd(), &collector.cache);
        errdefer collector.records.deinit();

        try collector.buffers_allocate(gpa);
    }

    fn buffers_allocate(collector: *Collector, gpa: std.mem.Allocator) !void {
        collector.events = try gpa.alloc(?PerfEvent, collector.sampler.states.len);
        errdefer gpa.free(collector.events);
        @memset(collector.events, null);
        collector.cpus_online = try gpa.alloc(bool, collector.sampler.states.len);
        errdefer gpa.free(collector.cpus_online);
        collector.count_keys = try gpa.alloc(CountKey, cpu_wire.counts_max);
        errdefer gpa.free(collector.count_keys);
        collector.count_values = try gpa.alloc(u64, cpu_wire.counts_max);
        errdefer gpa.free(collector.count_values);
        collector.stacks = try gpa.alloc(window.Stack, cpu_wire.counts_max);
    }

    pub fn deinit(collector: *Collector, gpa: std.mem.Allocator) void {
        collector.stop();
        gpa.free(collector.stacks);
        gpa.free(collector.count_values);
        gpa.free(collector.count_keys);
        gpa.free(collector.cpus_online);
        gpa.free(collector.events);
        collector.records.deinit();
        collector.cache.deinit(gpa);
        collector.sampler.deinit(gpa);
        collector.* = undefined;
    }

    /// Starts sampling `tgid` on every online CPU.
    pub fn start(collector: *Collector, tgid: u32) !void {
        assert(tgid > 0);
        assert(collector.tgid == 0);
        for (collector.events) |event| assert(event == null);

        collector.tgid = tgid;
        try collector.sampler.config_write(.{ .tgid = tgid, .generation = collector.generation });
        errdefer collector.stop();

        try collector.cpus_sync();
        const events_open = collector.events_open_count();
        if (events_open == 0) return error.NoCpuOnline;
        log.debug("sampling tgid {d} at {d} Hz on {d} CPUs", .{
            tgid, collector.sample_hz, events_open,
        });
    }

    /// Closes every perf event, so no new sample starts. Safe to call more than once. The
    /// program and its maps stay, so the counts of the run can still be collected.
    pub fn stop(collector: *Collector) void {
        for (collector.events) |*slot| {
            if (slot.*) |*event| event.deinit();
            slot.* = null;
        }
        collector.tgid = 0;
    }

    /// Opens an event on every CPU that came online since the last call, and closes the events
    /// of CPUs that went offline. Runs at start and at every report: a CPU that comes online
    /// during a run is sampled from the next report on.
    ///
    /// A CPU that goes offline and comes back between two reports keeps its old event, and
    /// whether the kernel keeps a CPU's events across that is not something the agent relies
    /// on knowing: such a CPU may go unsampled until it goes offline at a report again.
    fn cpus_sync(collector: *Collector) !void {
        assert(collector.tgid > 0);
        cpus.online_read(collector.cpus_online) catch |err| {
            // Without the list, try every possible CPU: an offline one refuses its event.
            log.warn("cannot read the online CPUs ({s}): trying all of them", .{@errorName(err)});
            @memset(collector.cpus_online, true);
        };

        for (collector.events, collector.cpus_online, 0..) |*slot, online, cpu| {
            if (online) {
                if (slot.* == null) slot.* = try collector.event_open(@intCast(cpu));
            } else {
                if (slot.*) |*event| {
                    event.deinit();
                    slot.* = null;
                    log.debug("cpu {d} went offline", .{cpu});
                }
            }
        }
    }

    /// The event sampling `cpu`, or null when it is offline after all (it went offline since
    /// the list was read).
    fn event_open(collector: *const Collector, cpu: u32) !?PerfEvent {
        var event = PerfEvent.cpu_clock_open(cpu, collector.sample_hz) catch |err| {
            switch (err) {
                error.CpuOffline => return null,
                else => return err,
            }
        };
        errdefer event.deinit();
        try event.program_attach(collector.sampler.program.fd);
        try event.enable();
        return event;
    }

    fn events_open_count(collector: *const Collector) u32 {
        var count: u32 = 0;
        for (collector.events) |event| {
            if (event != null) count += 1;
        }
        return count;
    }

    /// Reads the ring buffer into the frame cache, so it never fills up between reports.
    pub fn tick(collector: *Collector) !void {
        _ = try collector.records.consume();
    }

    /// The first half of a report: from now on the kernel counts under a new generation, and
    /// the frame cache forgets the epoch no window can need any more.
    pub fn generation_advance(collector: *Collector) !void {
        assert(!collector.generation_advanced);
        if (collector.tgid > 0) try collector.cpus_sync();
        collector.generation +%= 1;
        try collector.sampler.config_write(.{
            .tgid = collector.tgid,
            .generation = collector.generation,
        });
        collector.cache.epoch_advance();
        collector.generation_advanced = true;
    }

    /// The second half of a report: the samples counted since the previous report. The window
    /// refers to the collector's buffers: it is valid until the next `generation_advance`.
    pub fn collect(collector: *Collector) !Window {
        assert(collector.generation_advanced);
        collector.generation_advanced = false;

        // Counts first, then the ring: the kernel sends a stack's record before its count, so
        // every count drained now has its record in the ring or the cache already.
        const count = try collector.sampler.counts_drain(
            collector.count_keys,
            collector.count_values,
            collector.generation,
        );
        _ = try collector.records.consume();

        const built = window.stacks_build(
            collector.stacks,
            collector.count_keys[0..count],
            collector.count_values[0..count],
            &collector.cache,
        );
        const loss = try collector.loss_since_previous(built.frames_missing);
        return .{
            .sample_hz = collector.sample_hz,
            .samples = built.samples,
            .stacks = built.stacks,
            .stops = built.stops,
            .loss = loss,
        };
    }

    fn loss_since_previous(collector: *Collector, frames_missing: u64) !window.Loss {
        const counters = try collector.sampler.counters_read();
        const previous = collector.counters_previous;
        // The kernel's counters only grow.
        assert(counters.records_dropped >= previous.records_dropped);
        assert(counters.counts_insert_failed >= previous.counts_insert_failed);
        assert(counters.walks_abandoned >= previous.walks_abandoned);

        const records_malformed = collector.cache.records_malformed;
        const loss = window.Loss{
            .ring_full = counters.records_dropped - previous.records_dropped,
            .counts_full = counters.counts_insert_failed - previous.counts_insert_failed,
            .frames_missing = frames_missing,
            .records_malformed = records_malformed - collector.records_malformed_previous,
            .walks_abandoned = counters.walks_abandoned - previous.walks_abandoned,
        };
        collector.counters_previous = counters;
        collector.records_malformed_previous = records_malformed;
        return loss;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("../testing/process.zig");
const process = @import("../os/process.zig");

const Fixture = struct {
    tables: Tables,
    collector: Collector,

    /// Skips the test without the rights to load BPF programs.
    fn init(fixture: *Fixture) !void {
        fixture.tables.init(testing.allocator) catch |err| switch (err) {
            error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
            else => return err,
        };
        errdefer fixture.tables.deinit(testing.allocator);
        try fixture.collector.init(testing.allocator, &fixture.tables, .{ .sample_hz = 999 });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.collector.deinit(testing.allocator);
        fixture.tables.deinit(testing.allocator);
    }

    fn report(fixture: *Fixture) !Window {
        try fixture.collector.generation_advance();
        return fixture.collector.collect();
    }
};

/// Every window must agree with itself.
fn window_expect_consistent(w: *const Window) !void {
    var stacks_sum: u64 = 0;
    for (w.stacks) |stack| stacks_sum += stack.samples;
    try testing.expectEqual(w.samples, stacks_sum);

    var stops_sum: u64 = 0;
    for (w.stops) |samples| stops_sum += samples;
    try testing.expectEqual(w.samples, stops_sum);

    try testing.expectEqual(@as(u64, 0), w.loss.frames_missing);
    try testing.expectEqual(@as(u64, 0), w.loss.records_malformed);
    try testing.expectEqual(@as(u64, 0), w.loss.walks_abandoned);

    var index: usize = 1;
    while (index < w.stacks.len) : (index += 1) {
        try testing.expect(w.stacks[index - 1].samples >= w.stacks[index].samples);
    }
}

test "a window before start is empty (needs root, skipped otherwise)" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();

    const w = try fixture.report();
    try testing.expectEqual(@as(u64, 0), w.samples);
    try window_expect_consistent(&w);
}

test "every walk lands in exactly one window, across several (needs root, skipped otherwise)" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();

    try fixture.collector.start(process.current_pid());
    var samples_total: u64 = 0;
    var round: u32 = 0;
    while (round < 4) : (round += 1) {
        child_process.cpu_burn(300);
        try fixture.collector.tick();
        const w = try fixture.report();
        try window_expect_consistent(&w);
        samples_total += w.samples;
    }
    fixture.collector.stop();
    // Two more reports: the last generation, then any sample that read it late.
    for (0..2) |_| {
        const w = try fixture.report();
        try window_expect_consistent(&w);
        samples_total += w.samples;
    }

    const counters = try fixture.collector.sampler.counters_read();
    std.debug.print("walks={d} kernel={d} sent={d} repeated={d} dropped={d} counts_full={d}\n", .{
        counters.walks_completed, counters.walks_from_kernel, counters.records_sent,
        counters.stacks_repeated, counters.records_dropped,   counters.counts_insert_failed,
    });
    try testing.expect(counters.walks_completed > 100);
    // Every walk is a repeat, a sent record, or a drop.
    try testing.expectEqual(
        counters.walks_completed,
        counters.stacks_repeated + counters.records_sent + counters.records_dropped,
    );
    // Every counted walk is in exactly one window.
    const walks_lost = counters.records_dropped + counters.counts_insert_failed;
    try testing.expectEqual(counters.walks_completed - walks_lost, samples_total);
}

test "without unwind tables, stacks are one frame and stop at no_mapping (needs root)" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();

    try fixture.collector.start(process.current_pid());
    child_process.cpu_burn(500);
    fixture.collector.stop();
    const w = try fixture.report();
    try window_expect_consistent(&w);
    try testing.expect(w.samples > 0);

    // The tables were never synced, so nearly every walk ends at its first frame.
    const no_mapping = w.stops[@intFromEnum(window.StopReason.no_mapping)];
    try testing.expect(no_mapping * 10 >= w.samples * 9);
    try testing.expectEqual(@as(usize, 1), w.stacks[0].user.len);
}

test "another process is not sampled (needs root, skipped otherwise)" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();

    // A child that only sleeps: the busy loop here must not be counted for it.
    const sleeper = try child_process.sleeper_spawn();
    defer child_process.child_reap(sleeper);
    try fixture.collector.start(sleeper);
    child_process.cpu_burn(300);
    fixture.collector.stop();
    const w = try fixture.report();
    try testing.expectEqual(@as(u64, 0), w.samples);
}
