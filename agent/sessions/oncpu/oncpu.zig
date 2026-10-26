const std = @import("std");
const oncpu = @import("ebpf");
const Event = @import("../../clibs/event.zig").Event;

const OnCpu = oncpu.OnCpu;
const CountEntry = oncpu.CountEntry;

/// What is remembered about a stack for as long as the collector runs.
const Known = struct {
    /// The cumulative count at the previous call.
    last: u64,
    stop: u8,
    flags: u8,
    user: []u64,
    kernel: []u64,
};

pub const StackSample = struct {
    /// How many samples hit exactly this stack in the window.
    samples: u64,
    /// Addresses, innermost first.
    user: []const u64,
    /// Kernel addresses, innermost first. Empty for samples taken in user code.
    kernel: []const u64,
    /// True when the innermost user address is a return address (the sample was inside a
    /// system call), false when it is the exact instruction that was running.
    leaf_is_return: bool = false,

    /// Why the walk of this stack ended, as a `Stop` code. 0 means unknown.
    stop: u8 = 0,
};

/// Samples that are missing or incomplete in a window, and why.
pub const StackLoss = struct {
    /// Samples that never reached the window because the ring was full. They are not in `samples`.
    dropped: u64 = 0,
    /// Samples that were counted but whose stack could not be remembered because the counts map
    /// was full. They are not in `samples` either.
    map_full: u64 = 0,
    /// Samples whose frames had not arrived yet. They are reported in a later window.
    held_back: u64 = 0,
    /// Ring records that could not be read.
    bad_records: u64 = 0,
    /// The samples of the window by the reason their walk stopped, indexed by `Stop`. The ones
    /// under `end` have a complete stack; all the others are cut, and this says where.
    by_stop: [16]u64 = [_]u64{0} ** 16,
};

pub const Window = struct {
    /// Samples in this window; always the sum over `stacks`.
    samples: u64,
    /// Most frequent first.
    stacks: []StackSample,
    /// Always 0: sampling is not switched off to read the counts. Kept for the report format.
    paused_ns: u64 = 0,
    lost: StackLoss = .{},
};

const OncpuSession = struct {
    gpa: std.mem.Allocator,
    oncpu: OnCpu,
    attached: usize,
    events: []Event,
    /// Keyed by the hash of the stack, which is what the program counts by.
    known: std.AutoHashMap(u64, Known),
    previous_dropped: u64 = 0,
    previous_map_full: u64 = 0,
    previous_problems: usize = 0,

    pub fn init(gpa: std.mem.Allocator) !OncpuSession {
        return .{
            .gpa = gpa,
            .oncpu = try OnCpu.init(gpa),
            .attached = 0,
            .events = &.{},
            .known = std.AutoHashMap(u64, Known).init(gpa),
        };
    }

    /// Detaches and closes every perf event. Safe to call more than once.
    /// The program and maps stay alive, so totals() and collect() still work.
    pub fn stop(self: *OncpuSession) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        if (self.events.len > 0) self.gpa.free(self.events);
        self.events = &.{};
        self.attached = 0;
    }

    pub fn deinit(self: *OncpuSession) void {
        self.stop();
        var it = self.known.valueIterator();
        while (it.next()) |known| {
            self.gpa.free(known.user);
            self.gpa.free(known.kernel);
        }
        self.known.deinit();
        self.oncpu.deinit();
        self.* = undefined;
    }

    pub fn start(self: *OncpuSession, pid: u32, hz: u32) !void {
        if (self.events.len != 0) return error.AlreadyStarted;
        try self.oncpu.setTarget(pid);
        const events = try self.gpa.alloc(Event, self.oncpu.num_cpus);
        errdefer self.gpa.free(events);
        var attached: usize = 0;
        errdefer for (events[0..attached]) |*e| e.deinit();
        var cpu: u32 = 0;
        while (cpu < self.oncpu.num_cpus) : (cpu += 1) {
            var event = Event.openCpuClock(cpu, hz) catch |err| switch (err) {
                error.CpuOffline => continue,
                else => return err,
            };
            errdefer event.deinit();
            try event.attach(self.oncpu.program_fd);
            try event.enable();
            events[attached] = event;
            attached += 1;
        }
        self.events = events;
        self.attached = attached;
    }

    fn collect(self: *OncpuSession, area: std.mem.Allocator) !Window {
        var snapshot: std.ArrayList(CountEntry) = .empty;
        defer snapshot.deinit(self.gpa);
        try self.oncpu.snapshot(self.gpa, &snapshot);
        _ = try self.oncpu.ring_buffer.consume();
        try self.learnFrames();

        var list: std.ArrayList(StackSample) = .empty;
        var total: u64 = 0;
        var lost = StackLoss{};

        for (snapshot.items) |entry| {
            const known = self.known.getPtr(entry.key.stack_hash) orelse {
                lost.held_back += entry.count;
                continue;
            };
            const delta = entry.count -| known.last;
            known.last = entry.count;
            if (delta == 0) continue;

            try list.append(area, .{
                .samples = delta,
                .user = try area.dupe(u64, known.user),
                .kernel = try area.dupe(u64, known.kernel),
                .leaf_is_return = (known.flags & 1) != 0,
                .stop = known.stop,
            });

            total += delta;
            lost.by_stop[known.stop & 15] += delta;
        }
        const totals = try self.oncpu.totals();
        lost.dropped = totals.dropped - self.previous_dropped;
        lost.map_full = totals.map_full - self.previous_map_full;
        self.previous_dropped = totals.dropped;
        self.previous_map_full = totals.map_full;
        const problems = self.oncpu.ring_buffer.problems();
        lost.bad_records = problems - self.previous_problems;
        self.previous_problems = problems;
        std.mem.sort(StackSample, list.items, {}, moreSamples);

        return .{
            .samples = total,
            .stacks = list.items,
            .lost = lost,
        };
    }

    fn moreSamples(_: void, a: StackSample, b: StackSample) bool {
        return a.samples > b.samples;
    }

    fn learnFrames(self: *OncpuSession) !void {
        const stacks = self.oncpu.ring_buffer.getStacks();
        for (stacks) |*stack| {
            if (self.known.contains(stack.header.stack_hash)) continue;
            const user = try self.gpa.dupe(u64, stack.user());
            errdefer self.gpa.free(user);
            const kernel = try self.gpa.dupe(u64, stack.kernel());
            errdefer self.gpa.free(kernel);
            try self.known.put(stack.header.stack_hash, .{
                .last = 0,
                .stop = stack.header.stop_reason,
                .flags = stack.header.flags,
                .user = user,
                .kernel = kernel,
            });
        }
    }
};

// ---------- helpers ----------
const linux = std.os.linux;

fn requireRoot() !void {
    if (linux.geteuid() != 0) return error.SkipZigTest;
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Keeps one CPU busy for `ms` milliseconds.
fn burnMs(ms: u64) void {
    const end = nowNs() + ms * std.time.ns_per_ms;
    var x: u64 = 0;
    while (nowNs() < end) {
        x +%= 1;
        std.mem.doNotOptimizeAway(x);
    }
}

fn ownPid() u32 {
    return @intCast(linux.getpid());
}

const STOP_NO_MODULE: usize = 3;

fn sumStacks(w: Window) u64 {
    var n: u64 = 0;
    for (w.stacks) |s| n += s.samples;
    return n;
}

fn sumStops(w: Window) u64 {
    var n: u64 = 0;
    for (w.lost.by_stop) |v| n += v;
    return n;
}

/// Every window must agree with itself.
fn expectWindowConsistent(w: Window) !void {
    try std.testing.expectEqual(w.samples, sumStacks(w));
    try std.testing.expectEqual(w.samples, sumStops(w));
    try std.testing.expectEqual(@as(u64, 0), w.lost.held_back);
    try std.testing.expectEqual(@as(u64, 0), w.lost.bad_records);
}

test "OncpuSession: second start returns AlreadyStarted" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    try s.start(ownPid(), 99);
    try std.testing.expectError(error.AlreadyStarted, s.start(ownPid(), 99));
}

test "OncpuSession: stop can be called twice and start works again" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    try s.start(ownPid(), 99);
    s.stop();
    s.stop();
    try s.start(ownPid(), 99);
}

test "totals: nothing is counted before start" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    const t = try s.oncpu.totals();
    try std.testing.expectEqual(@as(u64, 0), t.walks);
    try std.testing.expectEqual(@as(u64, 0), t.sent);
}

test "collect: empty window before start" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const w = try s.collect(arena.allocator());
    try std.testing.expectEqual(@as(u64, 0), w.samples);
    try std.testing.expectEqual(@as(usize, 0), w.stacks.len);
    try expectWindowConsistent(w);
}

test "samples flow: a busy process gets walks" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    try s.start(ownPid(), 999);
    burnMs(1000);
    s.stop();

    const t = try s.oncpu.totals();
    std.debug.print("walks={} kernel={} sent={} repeats={} dropped={} map_full={}\n", .{
        t.walks, t.kernel_walks, t.sent, t.repeats, t.dropped, t.map_full,
    });
    try std.testing.expect(t.walks > 50);
}

test "collect: identities hold (main end-to-end test)" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var total_samples: u64 = 0;

    try s.start(ownPid(), 999);
    burnMs(1000);

    // A window taken while sampling is still running.
    const w1 = try s.collect(arena.allocator());
    try std.testing.expect(w1.samples > 0);
    try expectWindowConsistent(w1);
    total_samples += w1.samples;

    // Freeze the counters, then take the final window.
    s.stop();
    const w2 = try s.collect(arena.allocator());
    try expectWindowConsistent(w2);
    total_samples += w2.samples;

    const t = try s.oncpu.totals();
    std.debug.print("total_samples={} walks={} sent={} repeats={} dropped={} map_full={}\n", .{
        total_samples, t.walks, t.sent, t.repeats, t.dropped, t.map_full,
    });

    // Identity 1: every walk is a repeat, a sent record, or a drop.
    try std.testing.expectEqual(t.walks, t.repeats + t.sent + t.dropped);
    // Identity 2: every counted walk shows up in exactly one window.
    try std.testing.expectEqual(t.walks - t.dropped - t.map_full, total_samples);
}

test "collect: a second collect with no new samples is empty" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try s.start(ownPid(), 999);
    burnMs(500);
    s.stop();

    const first = try s.collect(arena.allocator());
    try std.testing.expect(first.samples > 0);

    const again = try s.collect(arena.allocator());
    try std.testing.expectEqual(@as(u64, 0), again.samples);
    try std.testing.expectEqual(@as(usize, 0), again.stacks.len);
    try expectWindowConsistent(again);
}

test "collect: windows add up across several collects" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try s.start(ownPid(), 999);

    var total: u64 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        burnMs(300);
        const w = try s.collect(arena.allocator());
        try expectWindowConsistent(w);
        total += w.samples;
    }

    s.stop();
    const last = try s.collect(arena.allocator());
    try expectWindowConsistent(last);
    total += last.samples;

    const t = try s.oncpu.totals();
    try std.testing.expectEqual(t.walks - t.dropped - t.map_full, total);
}

test "no tables loaded: stacks are one frame with stop reason no_module" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try s.start(ownPid(), 999);
    burnMs(1000);
    s.stop();

    const w = try s.collect(arena.allocator());
    try std.testing.expect(w.samples > 0);

    // Nearly everything is cut at the first frame for lack of a table.
    try std.testing.expect(w.lost.by_stop[STOP_NO_MODULE] * 10 >= w.samples * 9);

    // The hottest stack is the busy loop: one user frame.
    try std.testing.expect(w.stacks.len >= 1);
    try std.testing.expectEqual(@as(usize, 1), w.stacks[0].user.len);

    // Hottest first.
    var i: usize = 1;
    while (i < w.stacks.len) : (i += 1) {
        try std.testing.expect(w.stacks[i - 1].samples >= w.stacks[i].samples);
    }
}

test "a different target pid is not sampled" {
    try requireRoot();
    var s = try OncpuSession.init(std.testing.allocator);
    defer s.deinit();

    // pid 1 is not this process, so a busy loop here must not be counted.
    try s.start(1, 999);
    burnMs(500);
    s.stop();

    const t = try s.oncpu.totals();
    try std.testing.expectEqual(@as(u64, 0), t.walks);
}
