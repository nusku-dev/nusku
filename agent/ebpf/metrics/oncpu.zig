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

const StackSample = struct {
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
};

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
    /// Totals as of the previous collect(), so each window reports only new samples.
    previous: std.AutoHashMapUnmanaged(StackKey, u64),

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
            .previous = .empty,
        };
    }
    /// Loads the program and starts sampling `pid` at `hz` samples per second on every CPU.
    /// Needs root. The caller has already checked that `pid` is valid and exists.
    pub fn start(self: *OnCpu, pid: u32, hz: u32) !void {
        if (self.attached != 0) return error.AlreadyStarted;

        std.debug.assert(sys.isValidPid(pid));

        // Set the target before attaching: until then every sample is ignored.
        const slot = std.mem.toBytes(@as(u32, 0));
        const target = std.mem.toBytes(pid);
        try self.target_pid.map.update(&slot, &target);
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
    /// lives in `arena`; release it by resetting or deinitializing the arena.
    pub fn collect(self: *OnCpu, result_allocator: std.mem.Allocator) !Window {
        var list: std.ArrayList(StackSample) = .empty;
        var updates: std.ArrayList(struct {
            key: StackKey,
            value: u64,
        }) = .empty;

        var total: u64 = 0;
        var prev: ?StackKey = null;

        while (try self.counts.nextKey(prev)) |key| {
            prev = key;

            const now = (try self.counts.lookup(key)) orelse continue;
            const before = self.previous.get(key) orelse 0;
            if (now <= before) continue;

            const user = try self.readStack(result_allocator, key.user_stack_id);
            const kernel = try self.readStack(result_allocator, key.kernel_stack_id);

            try list.append(result_allocator, .{
                .samples = now - before,
                .user = user,
                .kernel = kernel,
            });

            try updates.append(result_allocator, .{
                .key = key,
                .value = now,
            });

            total += now - before;
        }

        // Commit the new counter values only after building the result.
        for (updates.items) |update| {
            try self.previous.put(self.allocator, update.key, update.value);
        }

        std.mem.sort(StackSample, list.items, {}, moreSamples);

        return .{
            .samples = total,
            .stacks = list.items,
        };
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
        self.previous.deinit(self.allocator);
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

    // Nothing is lost or counted twice: the two windows add up to the kernel's own total.
    var kernel_total: u64 = 0;
    var prev: ?StackKey = null;
    while (try cpu.counts.nextKey(prev)) |key| {
        prev = key;
        kernel_total += (try cpu.counts.lookup(key)) orelse 0;
    }
    try std.testing.expectEqual(kernel_total, first.samples + second.samples);

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
