//! The on-CPU collector. The BPF program counts every distinct stack once and sends its frames
//! to the ring the first time it sees it. Each call of `collect` reads the cumulative counts,
//! then the ring, and reports the difference since the previous call. Sampling is never paused.
const std = @import("std");
const unwind = @import("unwind");
const probe_mod = @import("oncpuprobe.zig");

/// Why a walk ended. `end` is a complete stack; every other value is a stack that is cut.
pub const Stop = unwind.compactwalk.Stop;

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

    pub fn stopName(code: usize) []const u8 {
        return if (std.enums.fromInt(Stop, code)) |s| @tagName(s) else "unknown";
    }
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

/// What is remembered about a stack for as long as the collector runs.
const Known = struct {
    /// The cumulative count at the previous call.
    last: u64,
    stop: u8,
    flags: u8,
    user: []u64,
    kernel: []u64,
};

pub const OnCpu = struct {
    allocator: std.mem.Allocator,
    probe: probe_mod.OncpuProbe,
    /// Keyed by the hash of the stack, which is what the program counts by.
    known: std.AutoHashMap(u64, Known),
    previous_dropped: u64 = 0,
    previous_map_full: u64 = 0,
    previous_problems: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !OnCpu {
        var probe = try probe_mod.OncpuProbe.init(allocator);
        errdefer probe.deinit();
        return .{
            .allocator = allocator,
            .probe = probe,
            .known = std.AutoHashMap(u64, Known).init(allocator),
        };
    }

    /// The table maps of the program. The caller fills them before `start`.
    pub fn tables(self: *OnCpu) !@import("../loader/tablemaps.zig").TableMaps {
        return self.probe.tables();
    }

    /// Starts sampling `pid` at `hz` samples per second on every CPU. Needs root.
    pub fn start(self: *OnCpu, pid: u32, hz: u32) !void {
        try self.probe.begin(pid, hz);
    }

    /// What was sampled since the previous call (or since start). Everything in the result
    /// lives in `result_allocator`; release it by resetting or deinitializing that arena.
    pub fn collect(self: *OnCpu, result_allocator: std.mem.Allocator) !Window {
        // The counts first and the ring second. The program puts the frames in the ring
        // before it creates the count, so every count seen here has its frames waiting.
        var snapshot: std.ArrayList(probe_mod.Drained) = .empty;
        defer snapshot.deinit(self.allocator);
        try self.probe.snapshot(self.allocator, &snapshot);
        _ = try self.probe.consume();
        try self.learnFrames();

        var list: std.ArrayList(StackSample) = .empty;
        var total: u64 = 0;
        var lost = StackLoss{};

        for (snapshot.items) |entry| {
            const known = self.known.getPtr(entry.key.hash) orelse {
                // Not expected. Counted, and reported when the frames arrive.
                lost.held_back += entry.count;
                continue;
            };
            const delta = entry.count -| known.last;
            known.last = entry.count;
            if (delta == 0) continue;

            try list.append(result_allocator, .{
                .samples = delta,
                .user = try result_allocator.dupe(u64, known.user),
                .kernel = try result_allocator.dupe(u64, known.kernel),
                .leaf_is_return = (known.flags & 1) != 0,
                .stop = known.stop,
            });
            total += delta;
            lost.by_stop[known.stop & 15] += delta;
        }

        const totals = try self.probe.totals();
        lost.dropped = totals.dropped - self.previous_dropped;
        lost.map_full = totals.map_full - self.previous_map_full;
        self.previous_dropped = totals.dropped;
        self.previous_map_full = totals.map_full;
        const problems = self.probe.problems();
        lost.bad_records = problems - self.previous_problems;
        self.previous_problems = problems;

        std.mem.sort(StackSample, list.items, {}, moreSamples);
        return .{ .samples = total, .stacks = list.items, .lost = lost };
    }

    fn moreSamples(_: void, a: StackSample, b: StackSample) bool {
        return a.samples > b.samples;
    }

    /// Keeps the frames of the stacks that arrived in the ring since the last call.
    fn learnFrames(self: *OnCpu) !void {
        for (self.probe.stacks()) |*stack| {
            // A race between two CPUs can send the same stack twice: keep the first.
            if (self.known.contains(stack.hash)) continue;
            const user = try self.allocator.dupe(u64, stack.user());
            errdefer self.allocator.free(user);
            const kernel = try self.allocator.dupe(u64, stack.kernel());
            errdefer self.allocator.free(kernel);
            try self.known.put(stack.hash, .{
                .last = 0,
                .stop = stack.stop,
                .flags = stack.flags,
                .user = user,
                .kernel = kernel,
            });
        }
        self.probe.clearStacks();
    }

    pub fn deinit(self: *OnCpu) void {
        var it = self.known.valueIterator();
        while (it.next()) |known| {
            self.allocator.free(known.user);
            self.allocator.free(known.kernel);
        }
        self.known.deinit();
        self.probe.deinit();
        self.* = undefined;
    }
};
