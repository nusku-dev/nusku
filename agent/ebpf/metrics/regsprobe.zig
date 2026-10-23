//! Step 1a of the BPF unwinder: attaches the register probe to this very process, so a test can
//! compare what the kernel program saw with what is known.
const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const TypedMap = @import("../loader/map.zig").TypedMap;

const RegSlot = extern struct {
    samples: u64,
    user_mode: u64,
    same_ip: u64,
    ip: u64,
    sp: u64,
    bp: u64,
    ctx_ip: u64,
    ctx_cs: u64,
};
const max_cpus = 256;

const Probe = struct {
    allocator: std.mem.Allocator,
    loader: l.Loader,
    target: l.MapRef,
    regs_map: l.MapRef,
    regs: TypedMap(u32, RegSlot),
    events: []perf.Event,
    attached: usize,

    fn start(allocator: std.mem.Allocator, pid: u32, hz: u32) !Probe {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));
        var loader = l.Loader.init(allocator, elf);
        errdefer loader.deinit();
        var target = try loader.createMap("target_pid");
        errdefer target.map.deinit();
        var regs_map = try loader.createMap("regs_debug");
        errdefer regs_map.map.deinit();
        const maps = [_]l.MapRef{ target, regs_map };
        const program_fd = try loader.load(.perf_event, "perf_event/regs", "regsProbe", &maps);

        const slot = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(pid);
        try target.map.update(&slot, &value);

        const ncpu = try sys.numPossibleCpus();
        const events = try allocator.alloc(perf.Event, ncpu);
        errdefer allocator.free(events);
        var attached: usize = 0;
        errdefer for (events[0..attached]) |*e| e.deinit();
        var cpu: u32 = 0;
        while (cpu < ncpu) : (cpu += 1) {
            var event = perf.Event.openCpuClock(cpu, hz) catch |err| switch (err) {
                error.CpuOffline => continue,
                else => return err,
            };
            errdefer event.deinit();
            try event.attach(program_fd);
            try event.enable();
            events[attached] = event;
            attached += 1;
        }
        return .{
            .allocator = allocator,
            .loader = loader,
            .target = target,
            .regs_map = regs_map,
            .regs = try TypedMap(u32, RegSlot).init(regs_map.map),
            .events = events,
            .attached = attached,
        };
    }

    /// Samples stop being recorded, so the slots can be read without a CPU writing to one.
    fn pause(self: *Probe) !void {
        const slot = std.mem.toBytes(@as(u32, 0));
        const zero = std.mem.toBytes(@as(u32, 0));
        try self.target.map.update(&slot, &zero);
        sys.sleepMs(5);
    }

    fn deinit(self: *Probe) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        self.allocator.free(self.events);
        self.loader.deinit();
        self.target.map.deinit();
        self.regs_map.map.deinit();
    }
};

fn skipWithoutPrivilege(err: anyerror) anyerror {
    if (err == error.PermissionDenied or err == error.NotSupported) return error.SkipZigTest;
    return err;
}

noinline fn spinUser(ms: u64, marker: *u8) u64 {
    const end = sys.nowMs() + ms;
    var x: u64 = 1;
    while (sys.nowMs() < end) {
        var i: u32 = 0;
        while (i < 20_000_000) : (i += 1) {
            x = x *% 6364136223846793005 +% 1;
            marker.* = @truncate(x);
        }
    }
    return x;
}

noinline fn spinSyscalls(ms: u64) u64 {
    const end = sys.nowMs() + ms;
    var n: u64 = 0;
    while (sys.nowMs() < end) {
        var i: u32 = 0;
        while (i < 2000) : (i += 1) n +%= sys.currentPid();
    }
    return n;
}

const user_limit: u64 = 0x0000_8000_0000_0000;
const kernel_start: u64 = 0xffff_8000_0000_0000;

fn near(a: u64, b: u64, limit: u64) bool {
    const d: i64 = @bitCast(a -% b);
    return @abs(d) < limit;
}

test "samples in user code: the task's registers equal the sampled ones, and point into our function" {
    var probe = Probe.start(std.testing.allocator, sys.currentPid(), 999) catch |e| return skipWithoutPrivilege(e);
    defer probe.deinit();

    var marker: u8 = 0;
    std.mem.doNotOptimizeAway(spinUser(400, &marker));
    try probe.pause();

    const function = @intFromPtr(&spinUser);
    var total: u64 = 0;
    var user_mode: u64 = 0;
    var checked: usize = 0;
    for (0..max_cpus) |cpu| {
        const slot = (try probe.regs.lookup(@intCast(cpu))) orelse continue;
        if (slot.samples == 0) continue;
        total += slot.samples;
        user_mode += slot.user_mode;
        // Every sample in user mode: the registers read from the task are the sampled ones.
        try std.testing.expectEqual(slot.user_mode, slot.same_ip);
        if (slot.samples > 20) {
            try std.testing.expect(slot.ip -% function < 16 * 1024);
            try std.testing.expect(near(slot.sp, @intFromPtr(&marker), 64 * 1024));
            checked += 1;
        }
    }
    std.debug.print("regs: user spin: {d} samples, {d} in user mode, {d} CPUs checked in detail\n", .{ total, user_mode, checked });
    try std.testing.expect(total >= 100);
    try std.testing.expect(checked >= 1);
}

test "samples inside the kernel: the task's registers still give the user side" {
    var probe = Probe.start(std.testing.allocator, sys.currentPid(), 999) catch |e| return skipWithoutPrivilege(e);
    defer probe.deinit();

    var marker: u8 = 0;
    std.mem.doNotOptimizeAway(spinSyscalls(400));
    try probe.pause();

    var total: u64 = 0;
    var in_kernel: u64 = 0;
    for (0..max_cpus) |cpu| {
        const slot = (try probe.regs.lookup(@intCast(cpu))) orelse continue;
        if (slot.samples == 0) continue;
        total += slot.samples;
        in_kernel += slot.samples - slot.user_mode;
        try std.testing.expectEqual(slot.user_mode, slot.same_ip);
        if (slot.samples > 20) {
            // Wherever the last sample landed, the user side is a user address on our stack.
            try std.testing.expect(slot.ip < user_limit);
            try std.testing.expect(near(slot.sp, @intFromPtr(&marker), 1 << 20));
            if ((slot.ctx_cs & 3) == 0) try std.testing.expect(slot.ctx_ip >= kernel_start);
        }
    }
    std.debug.print("regs: syscall spin: {d} samples, {d} of them inside the kernel\n", .{ total, in_kernel });
    try std.testing.expect(total >= 100);
    try std.testing.expect(in_kernel > 0);
}
