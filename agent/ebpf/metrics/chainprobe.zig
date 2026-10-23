//! Harness for the tail-call chain probe: a program that jumps to itself until the kernel
//! refuses, to measure how many invocations one sample gets.
const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const TypedMap = @import("../loader/map.zig").TypedMap;

pub const max_cpus = 256;

pub const ChainSlot = extern struct {
    active: u64,
    depth: u64,
    chains: u64,
    min_depth: u64,
    max_depth: u64,
};

pub const ChainProbe = struct {
    allocator: std.mem.Allocator,
    loader: l.Loader,
    target: l.MapRef,
    progs: l.MapRef,
    debug: l.MapRef,
    slots: TypedMap(u32, ChainSlot),
    events: []perf.Event,
    attached: usize,
    program_fd: c_int,

    pub fn init(allocator: std.mem.Allocator) !ChainProbe {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));
        var loader = l.Loader.init(allocator, elf);
        errdefer loader.deinit();
        var target = try loader.createMap("target_pid");
        errdefer target.map.deinit();
        var progs = try loader.createMap("chain_progs");
        errdefer progs.map.deinit();
        var debug = try loader.createMap("chain_debug");
        errdefer debug.map.deinit();

        const maps = [_]l.MapRef{ target, progs, debug };
        const program_fd = try loader.load(.perf_event, "perf_event/chain", "chainProbe", &maps);

        // The program jumps to slot 0, so slot 0 must hold the program itself.
        const index = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(@as(u32, @intCast(program_fd)));
        try progs.map.update(&index, &value);

        return .{
            .allocator = allocator,
            .loader = loader,
            .target = target,
            .progs = progs,
            .debug = debug,
            .slots = try TypedMap(u32, ChainSlot).init(debug.map),
            .events = &.{},
            .attached = 0,
            .program_fd = program_fd,
        };
    }

    fn setTarget(self: *ChainProbe, pid: u32) !void {
        const key = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(pid);
        try self.target.map.update(&key, &value);
    }

    pub fn begin(self: *ChainProbe, pid: u32, hz: u32) !void {
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
        self.events = events;
        self.attached = attached;
    }

    pub fn pause(self: *ChainProbe) !void {
        try self.setTarget(0);
        sys.sleepMs(5);
    }

    pub fn slot(self: *ChainProbe, cpu: u32) !ChainSlot {
        return (try self.slots.lookup(cpu)) orelse error.NotFound;
    }

    pub fn deinit(self: *ChainProbe) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        if (self.events.len > 0) self.allocator.free(self.events);
        self.loader.deinit();
        self.target.map.deinit();
        self.progs.map.deinit();
        self.debug.map.deinit();
    }
};

test "a program that tail calls itself runs 34 times per sample" {
    var probe = ChainProbe.init(std.testing.allocator) catch |e| {
        if (e == error.PermissionDenied or e == error.NotSupported) return error.SkipZigTest;
        return e;
    };
    defer probe.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    try probe.begin(pid, 999);

    var x: u64 = 1;
    var i: u64 = 0;
    while (i < 100_000_000) : (i += 1) {
        x = x *% 6364136223846793005 +% 1;
        std.mem.doNotOptimizeAway(x);
    }
    try probe.pause();

    var chains: u64 = 0;
    var cpus: usize = 0;
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    for (0..max_cpus) |cpu| {
        const slot = try probe.slot(@intCast(cpu));
        if (slot.chains == 0) continue;
        try std.testing.expectEqual(@as(u64, 0), slot.active);
        chains += slot.chains;
        cpus += 1;
        lowest = @min(lowest, slot.min_depth);
        highest = @max(highest, slot.max_depth);
    }
    std.debug.print("chain: {d} chains on {d} CPUs, depth {d} to {d}\n", .{ chains, cpus, lowest, highest });
    try std.testing.expect(chains >= 100);
    try std.testing.expectEqual(@as(u64, 34), lowest);
    try std.testing.expectEqual(@as(u64, 34), highest);
}
