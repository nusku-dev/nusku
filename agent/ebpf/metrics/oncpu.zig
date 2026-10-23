const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const TypedMap = @import("../loader/map.zig").TypedMap;

const Error = l.Error;
const Loader = l.Loader;
const MapRef = l.MapRef;

// These must match agent/bpf/oncpu_kern.zig. The map sizes are checked when the maps are
// created, so a mismatch is an error at startup, not bad data.
const MAX_STACK_DEPTH = 127;

const StackKey = extern struct {
    tgid: u32,
    user_stack_id: i32, // negative: the kernel could not capture the stack
    kernel_stack_id: i32,
};
const StackTrace = [MAX_STACK_DEPTH]u64;

pub const StackSample = struct {
    /// How many samples hit exactly this pair of stacks in the window.
    samples: u64,
    /// Return addresses, innermost first. Empty if the kernel could not capture the stack
    /// (for example a user stack in a binary built without frame pointers).
    user: []const u64,
    kernel: []const u64,
};

pub const Window = struct {
    /// Samples in this window; always the sum over `stacks`.
    samples: u64,
    /// Most frequent first.
    stacks: []StackSample,

    /// How long sampling was switched off to read and empty the kernel tables. Samples that
    /// would have come in that time are missing, so counts are low by about this much of
    /// the window.
    paused_ns: u64 = 0,
    /// Samples counted above whose stack is missing, and why. A client can use this to see
    /// how far to trust the window.
    lost: StackLoss = .{},
};

/// How long to wait after switching sampling off, for a sample that was already running on
/// another CPU. One sample takes a few microseconds, so this is far more than enough.
const settle_ns = 200 * std.time.ns_per_us;

/// More than any table can hold. It only stops a loop that would otherwise never end if the
/// kernel behaved unexpectedly.
const drain_limit = 1 << 20;

/// Why a stack could not be recorded, from the error the kernel gave in place of a stack id.
const StackError = enum { none, no_stack, collision, other };

fn stackError(id: i32) StackError {
    if (id >= 0) return .none;
    return switch (-@as(i64, id)) {
        14 => .no_stack, // EFAULT: there was no stack to read
        17 => .collision, // EEXIST: the table's slot already holds a different stack
        else => .other,
    };
}

/// How many samples of a window have a stack that is missing, and why. Those samples are
/// still counted in `Window.samples`; only their frames are missing.
pub const StackLoss = struct {
    /// The user stack was lost because the kernel's table already held a different stack in its slot.
    user_collisions: u64 = 0,
    /// The same for the kernel stack.
    kernel_collisions: u64 = 0,
    /// There was no user stack to read, for example because the sample was in a kernel thread.
    no_user_stack: u64 = 0,
    /// Any other error from the kernel. A sample with two such stacks is counted twice.
    other: u64 = 0,
};

fn countLoss(lost: *StackLoss, key: StackKey, samples: u64) void {
    switch (stackError(key.user_stack_id)) {
        .none => {},
        .no_stack => lost.no_user_stack += samples,
        .collision => lost.user_collisions += samples,
        .other => lost.other += samples,
    }
    // A sample taken in user code has no kernel stack at all, which is normal, not a loss.
    switch (stackError(key.kernel_stack_id)) {
        .none, .no_stack => {},
        .collision => lost.kernel_collisions += samples,
        .other => lost.other += samples,
    }
}

pub const OnCpu = struct {
    allocator: std.mem.Allocator,
    stacks: TypedMap(u32, StackTrace),
    counts: TypedMap(StackKey, u64),
    target_pid: MapRef,
    program_fd: c_int,
    loader: Loader,
    /// One perf event per online CPU: the first `attached` entries are live.
    events: []perf.Event,
    attached: usize,
    /// The process being sampled; what sampling is switched back to after a pause.
    pid: u32,

    pub fn init(allocator: std.mem.Allocator) Error!OnCpu {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));

        var loader = Loader.init(allocator, elf);
        errdefer loader.deinit();

        var stacks = try loader.createMap("stacks");
        errdefer stacks.map.deinit();

        var counts = try loader.createMap("counts");
        errdefer counts.map.deinit();

        var target_pid = try loader.createMap("target_pid");
        errdefer target_pid.map.deinit();

        const maps = [_]MapRef{ stacks, counts, target_pid };

        const program_fd = try loader.load(.perf_event, "perf_event", "onCpusample", &maps);

        const typed_stacks = try TypedMap(u32, StackTrace).init(stacks.map);
        const typed_counts = try TypedMap(StackKey, u64).init(counts.map);

        return .{
            .allocator = allocator,
            .loader = loader,
            .target_pid = target_pid,
            .program_fd = program_fd,
            .stacks = typed_stacks,
            .counts = typed_counts,
            .events = &.{},
            .attached = 0,
            .pid = 0,
        };
    }
    /// Loads the program and starts sampling `pid` at `hz` samples per second on every CPU.
    /// Needs root. The caller has already checked that `pid` is valid and exists.
    pub fn start(self: *OnCpu, pid: u32, hz: u32) !void {
        if (self.attached != 0) return error.AlreadyStarted;

        std.debug.assert(sys.isValidPid(pid));

        // Set the target before attaching: until then every sample is ignored.
        self.pid = pid;
        try self.setTarget(pid);

        const ncpu = try sys.numPossibleCpus();
        const events = try self.allocator.alloc(perf.Event, ncpu);
        errdefer self.allocator.free(events);

        var attached: usize = 0;
        errdefer for (events[0..attached]) |*e| e.deinit();

        var cpu: u32 = 0;
        while (cpu < ncpu) : (cpu += 1) {
            var event = perf.Event.openCpuClock(cpu, hz) catch |err| switch (err) {
                error.CpuOffline => continue,
                else => return err,
            };
            errdefer event.deinit();

            try event.attach(self.program_fd);
            try event.enable();
            events[attached] = event;
            attached += 1;
        }
        if (attached == 0) return error.NotFound;

        self.events = events;
        self.attached = attached;
    }

    /// What was sampled since the previous call (or since start). Everything in the result
    /// lives in `result_allocator`; release it by resetting or deinitializing that arena.
    ///
    /// Sampling is switched off while the kernel tables are read and emptied, so nothing can
    /// use a stack id while it is being deleted. Emptying them every window is what keeps them
    /// from filling up: a full table silently loses every stack that is new.
    pub fn collect(self: *OnCpu, result_allocator: std.mem.Allocator) !Window {
        const paused_at = sys.nowNs();
        try self.setTarget(0);
        sys.sleepNs(settle_ns);

        var window = self.drain(result_allocator) catch |err| {
            // Never leave sampling off because reading failed.
            self.setTarget(self.pid) catch {};
            return err;
        };
        try self.setTarget(self.pid);

        window.paused_ns = sys.nowNs() - paused_at;
        return window;
    }

    fn setTarget(self: *OnCpu, pid: u32) !void {
        const slot = std.mem.toBytes(@as(u32, 0));
        const target = std.mem.toBytes(pid);
        try self.target_pid.map.update(&slot, &target);
    }

    /// Reads every counter and every stack, then deletes them all. Sampling must be off.
    fn drain(self: *OnCpu, result_allocator: std.mem.Allocator) !Window {
        var list: std.ArrayList(StackSample) = .empty;
        var total: u64 = 0;

        // Walking forward from the previous key is cheap. Asking for the first key every time
        // is not: the kernel looks for it from the start of the table on each call. So
        // nothing is deleted while walking; the keys are collected and deleted afterwards.
        var count_keys: std.ArrayList(StackKey) = .empty;
        defer count_keys.deinit(self.allocator);

        var steps: usize = 0;
        var prev: ?StackKey = null;
        var lost: StackLoss = .{};

        while (try self.counts.nextKey(prev)) |key| {
            prev = key;
            steps += 1;
            if (steps > drain_limit) return error.Unexpected;

            try count_keys.append(self.allocator, key);
            const count = (try self.counts.lookup(key)) orelse 0;
            if (count == 0) continue;
            countLoss(&lost, key, count);

            const user = try self.readStack(result_allocator, key.user_stack_id);
            const kernel = try self.readStack(result_allocator, key.kernel_stack_id);
            try list.append(result_allocator, .{
                .samples = count,
                .user = user,
                .kernel = kernel,
            });
            total += count;
        }

        // Every stack in the table, including ones no counter points to (a counter that could
        // not be stored), so nothing is left behind to fill the table.
        var stack_ids: std.ArrayList(u32) = .empty;
        defer stack_ids.deinit(self.allocator);

        steps = 0;
        var prev_id: ?u32 = null;
        while (try self.stacks.nextKey(prev_id)) |id| {
            prev_id = id;
            steps += 1;
            if (steps > drain_limit) return error.Unexpected;
            try stack_ids.append(self.allocator, id);
        }

        for (count_keys.items) |key| _ = try self.counts.delete(key);
        for (stack_ids.items) |id| _ = try self.stacks.delete(id);

        std.mem.sort(StackSample, list.items, {}, moreSamples);
        return .{ .samples = total, .stacks = list.items, .lost = lost };
    }
    fn moreSamples(_: void, a: StackSample, b: StackSample) bool {
        return a.samples > b.samples;
    }

    fn readStack(self: OnCpu, allocator: std.mem.Allocator, id: i32) ![]const u64 {
        if (id < 0) return &.{}; // the kernel could not capture this stack
        const trace = (try self.stacks.lookup(@intCast(id))) orelse return &.{};
        var depth: usize = 0;
        while (depth < MAX_STACK_DEPTH and trace[depth] != 0) depth += 1; // zero ends the stack
        return try allocator.dupe(u64, trace[0..depth]);
    }

    pub fn deinit(self: *OnCpu) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        self.allocator.free(self.events);
        self.loader.deinit();
        self.target_pid.map.deinit();
        self.counts.raw.deinit();
        self.stacks.raw.deinit();
        self.* = undefined;
    }
};

const testing = std.testing;

fn burn(ms: u64) void {
    const until = sys.nowMs() + ms;
    var x: u64 = 0;
    while (sys.nowMs() < until) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

fn expectConsistent(window: Window) !void {
    var sum: u64 = 0;
    for (window.stacks, 0..) |s, i| {
        sum += s.samples;
        if (i > 0) try std.testing.expect(window.stacks[i - 1].samples >= s.samples);
    }
    try std.testing.expectEqual(window.samples, sum);
}

test "deinit is safe without starting" {
    var cpu = OnCpu.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    cpu.deinit();
}

test "collect reports only what is new since the previous call (needs root, skipped otherwise)" {
    var cpu = OnCpu.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer cpu.deinit();

    cpu.start(sys.currentPid(), 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    burn(300);
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena1.deinit();
    const first = try cpu.collect(arena1.allocator());

    burn(300);
    const slot = std.mem.toBytes(@as(u32, 0));
    const nobody = std.mem.toBytes(@as(u32, 0));
    try cpu.target_pid.map.update(&slot, &nobody);
    burn(20);

    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    const second = try cpu.collect(arena2.allocator());
    try expectConsistent(first);
    try expectConsistent(second);
    // 300 ms at 99 Hz is about 30 samples per window.
    try std.testing.expect(first.samples >= 5);
    try std.testing.expect(second.samples >= 5);

    std.debug.print("window 1: {d} samples in {d} stacks; window 2: {d} samples in {d} stacks\n", .{
        first.samples, first.stacks.len, second.samples, second.stacks.len,
    });
    if (first.stacks.len > 0) {
        const top = first.stacks[0];
        std.debug.print("top stack: {d} samples, {d} user frames, {d} kernel frames\n", .{ top.samples, top.user.len, top.kernel.len });
        for (top.user[0..@min(top.user.len, 4)]) |addr| std.debug.print("  user 0x{x}\n", .{addr});
    }
}

test "collect reports an empty window when no new samples arrive (needs root, skipped otherwise)" {
    var cpu = OnCpu.init(std.testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer cpu.deinit();

    cpu.start(sys.currentPid(), 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    // Generate samples for the first window.
    burn(300);

    var arena1 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena1.deinit();

    const first = try cpu.collect(arena1.allocator());
    try std.testing.expect(first.samples > 0);

    // Stop this process from contributing new samples.
    const slot = std.mem.toBytes(@as(u32, 0));
    const nobody = std.mem.toBytes(@as(u32, 0));
    try cpu.target_pid.map.update(&slot, &nobody);

    // Allow any in-flight samples to settle.
    burn(50);

    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();

    const second = try cpu.collect(arena2.allocator());

    try std.testing.expectEqual(@as(u64, 0), second.samples);
    try std.testing.expectEqual(@as(usize, 0), second.stacks.len);
}

test "start rejects a second call" {
    var cpu = OnCpu.init(std.testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer cpu.deinit();

    try cpu.start(sys.currentPid(), 99);

    try std.testing.expectError(
        error.AlreadyStarted,
        cpu.start(sys.currentPid(), 99),
    );

    // The original session should still collect samples.
    burn(200);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const window = try cpu.collect(arena.allocator());
    try std.testing.expect(window.samples > 0);
}

test "the kernel verifier accepts the program (needs root, skipped otherwise)" {
    var oncpu = OnCpu.init(testing.allocator) catch |err| {
        if (err == error.PermissionDenied or err == error.NotSupported) {
            return error.SkipZigTest;
        }
        return err;
    };

    defer oncpu.deinit();

    try testing.expect(oncpu.loader.program.?.fd >= 0);
}

test "draining empties both kernel tables (needs root, skipped otherwise)" {
    var cpu = OnCpu.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer cpu.deinit();

    cpu.start(sys.currentPid(), 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    burn(300);

    // Stop sampling first, so nothing can arrive while we look at the tables.
    try cpu.setTarget(0);
    sys.sleepNs(settle_ns);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const window = try cpu.drain(arena.allocator());
    try expectConsistent(window);
    try testing.expect(window.samples >= 5);

    try testing.expect((try cpu.counts.nextKey(null)) == null);
    try testing.expect((try cpu.stacks.nextKey(null)) == null);

    // And sampling works again afterwards, through the public path.
    try cpu.setTarget(cpu.pid);
    burn(300);
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const next = try cpu.collect(arena2.allocator());
    try expectConsistent(next);
    try testing.expect(next.samples >= 5);
}

test "collect reports how long sampling was off, and it stays short (needs root, skipped otherwise)" {
    var cpu = OnCpu.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer cpu.deinit();

    cpu.start(sys.currentPid(), 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    burn(300);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const window = try cpu.collect(arena.allocator());

    std.debug.print("sampling was off for {d} us\n", .{window.paused_ns / 1000});
    try testing.expect(window.paused_ns >= settle_ns);
    try testing.expect(window.paused_ns < 50 * std.time.ns_per_ms);
}

fn keyOf(user: i32, kernel: i32) StackKey {
    return .{ .tgid = 1, .user_stack_id = user, .kernel_stack_id = kernel };
}

test "stackError tells apart the failures that matter" {
    try testing.expectEqual(StackError.none, stackError(0));
    try testing.expectEqual(StackError.none, stackError(16383));
    try testing.expectEqual(StackError.no_stack, stackError(-14));
    try testing.expectEqual(StackError.collision, stackError(-17));
    try testing.expectEqual(StackError.other, stackError(-12));
    try testing.expectEqual(StackError.other, stackError(std.math.minInt(i32)));
}

test "countLoss counts what is missing and not a kernel stack that was never there" {
    var lost = StackLoss{};

    countLoss(&lost, keyOf(5, -14), 10); // user code: no kernel stack is normal
    try testing.expectEqual(StackLoss{}, lost);

    countLoss(&lost, keyOf(-17, -14), 3);
    countLoss(&lost, keyOf(5, -17), 2);
    countLoss(&lost, keyOf(-14, 7), 4);
    countLoss(&lost, keyOf(-12, 7), 1);
    countLoss(&lost, keyOf(-17, -17), 6); // both stacks lost
    try testing.expectEqual(StackLoss{
        .user_collisions = 9,
        .kernel_collisions = 8,
        .no_user_stack = 4,
        .other = 1,
    }, lost);
}
