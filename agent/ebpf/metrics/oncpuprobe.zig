//! Harness for the production walk (`oncpuWalk`): loads it with the table maps and the ring,
//! samples one process on every CPU, and reads back the stacks the program sent.
const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const c = @import("../libc/import.zig").clibs;
const tablemaps = @import("../loader/tablemaps.zig");
const m = @import("../loader/map.zig");

pub const max_frames = 128;
pub const max_kframes = 32;
const header_bytes = 16;

/// A record of the ring, unpacked. The wire layout is in oncpu.ebpf.zig (`OncpuSlot`): a header
/// of hash (8 bytes), tgid (4), count (2), stop (1) and flags (1), then `count` addresses.
pub const Stack = struct {
    hash: u64,
    tgid: u32,
    count: u8,
    kcount: u8,
    stop: u8,
    flags: u8,
    frames: [max_frames + max_kframes]u64,

    pub fn user(self: *const Stack) []const u64 {
        return self.frames[0..self.count];
    }

    pub fn kernel(self: *const Stack) []const u64 {
        return self.frames[self.count..][0..self.kcount];
    }
};
/// The state of the program on one CPU. Must match `OncpuSlot` in oncpu.ebpf.zig.
pub const Slot = extern struct {
    active: u64,
    pc: u64,
    sp: u64,
    bp: u64,
    first: u64,
    fp_steps: u64,
    leaf_is_return: u64,
    hash: u64,
    count: u64,
    walks: u64,
    kernel_walks: u64,
    sent: u64,
    dropped: u64,
    repeats: u64,
    map_full: u64,
    stops: [16]u64,
    rec_hash: u64,
    rec_tgid: u32,
    rec_count: u8,
    rec_kcount: u8,
    rec_stop: u8,
    rec_flags: u8,
    frames: [max_frames + max_kframes]u64,
};

comptime {
    if (@sizeOf(Slot) != 1544) @compileError("OncpuSlot layout changed: update oncpu.ebpf.zig too");
}

/// The counters of all CPUs added up.
pub const Totals = struct {
    walks: u64 = 0,
    kernel_walks: u64 = 0,
    sent: u64 = 0,
    dropped: u64 = 0,
    repeats: u64 = 0,
    map_full: u64 = 0,
    stops: [16]u64 = [_]u64{0} ** 16,
};

/// Identifies a stack inside one process. Must match `CountKey` in oncpu.ebpf.zig.
pub const CountKey = extern struct {
    hash: u64,
    tgid: u32,
    reserved: u32,
};

/// One entry taken out of the counts map: how often this stack was sampled since the last drain.
pub const Drained = struct {
    key: CountKey,
    count: u64,
};

/// Where the callback puts what it reads. It lives on the heap because libbpf keeps the pointer.
const Sink = struct {
    stacks: []Stack,
    len: usize = 0,
    malformed: usize = 0,
    overflow: usize = 0,
};

fn onRecord(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    const sink: *Sink = @ptrCast(@alignCast(ctx.?));
    if (size < header_bytes) {
        sink.malformed += 1;
        return 0;
    }
    const base: [*]const u8 = @ptrCast(data.?);
    const bytes = base[0..size];
    const count = bytes[12];
    const kcount = bytes[13];
    if (count > max_frames or kcount > max_kframes or size != header_bytes + (@as(usize, count) + kcount) * 8) {
        sink.malformed += 1;
        return 0;
    }
    if (sink.len == sink.stacks.len) {
        sink.overflow += 1;
        return 0;
    }
    const out = &sink.stacks[sink.len];
    out.hash = std.mem.readInt(u64, bytes[0..8], .little);
    out.tgid = std.mem.readInt(u32, bytes[8..][0..4], .little);
    out.count = count;
    out.kcount = kcount;
    out.stop = bytes[14];
    out.flags = bytes[15];
    for (0..@as(usize, count) + kcount) |i| out.frames[i] = std.mem.readInt(u64, bytes[header_bytes + i * 8 ..][0..8], .little);
    sink.len += 1;
    return 0;
}

pub const OncpuProbe = struct {
    allocator: std.mem.Allocator,
    loader: l.Loader,
    target: l.MapRef,
    rows: l.MapRef,
    modules: l.MapRef,
    procs: l.MapRef,
    state: l.MapRef,
    progs: l.MapRef,
    ring: l.MapRef,
    counts: l.MapRef,
    reader: *c.struct_ring_buffer,
    sink: *Sink,
    program_fd: c_int,
    events: []perf.Event,
    attached: usize,

    /// Creates the maps and loads the program. Nothing is sampled until `begin`.
    pub fn init(allocator: std.mem.Allocator) !OncpuProbe {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));
        var loader = l.Loader.init(allocator, elf);
        errdefer loader.deinit();
        var target = try loader.createMap("target_pid");
        errdefer target.map.deinit();
        var rows = try loader.createMap("unwind_rows");
        errdefer rows.map.deinit();
        var modules = try loader.createMap("unwind_modules");
        errdefer modules.map.deinit();
        var procs = try loader.createMap("unwind_procs");
        errdefer procs.map.deinit();
        var state = try loader.createMap("oncpu_state");
        errdefer state.map.deinit();
        var progs = try loader.createMap("oncpu_progs");
        errdefer progs.map.deinit();
        var ring = try loader.createMap("ring");
        errdefer ring.map.deinit();

        var counts = try loader.createMap("oncpu_counts");
        errdefer counts.map.deinit();

        var maps: [8]l.MapRef = .{ target, rows, modules, procs, state, progs, ring, counts };
        const program_fd = try loader.load(.perf_event, "perf_event/oncpu_walk", "oncpuWalk", maps[0..8]);

        // A program that jumps to itself finds itself in slot 0.
        const index = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(@as(u32, @intCast(program_fd)));
        try progs.map.update(&index, &value);

        const allStacks = try allocator.alloc(Stack, 4096);
        errdefer allocator.free(allStacks);
        const sink = try allocator.create(Sink);
        errdefer allocator.destroy(sink);
        sink.* = .{ .stacks = allStacks };
        const reader = c.ring_buffer__new(ring.map.fd, onRecord, sink, null) orelse return error.RingBufferFailed;
        errdefer c.ring_buffer__free(reader);

        return .{
            .allocator = allocator,
            .loader = loader,
            .target = target,
            .rows = rows,
            .modules = modules,
            .procs = procs,
            .state = state,
            .progs = progs,
            .ring = ring,
            .reader = reader,
            .counts = counts,
            .sink = sink,
            .program_fd = program_fd,
            .events = &.{},
            .attached = 0,
        };
    }

    /// The table maps, for `writeModulesFrom` and `writeProcess`. The maps stay owned by the
    /// probe; the caller calls `deinit` on the result to free its row image.
    pub fn tables(self: *OncpuProbe) !tablemaps.TableMaps {
        return tablemaps.TableMaps.wrap(self.allocator, self.rows.map, self.modules.map, self.procs.map);
    }

    /// Samples of `pid` are recorded from now on (0 stops recording).
    pub fn setTarget(self: *OncpuProbe, pid: u32) !void {
        const index = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(pid);
        try self.target.map.update(&index, &value);
    }

    /// Starts sampling `pid` at `hz` on every CPU.
    pub fn begin(self: *OncpuProbe, pid: u32, hz: u32) !void {
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

    /// Stops recording, so the counters can be read while no CPU writes to them.
    pub fn pause(self: *OncpuProbe) !void {
        try self.setTarget(0);
        sys.sleepMs(5);
    }

    /// Reads everything that is in the ring now. Returns how many records it read.
    pub fn consume(self: *OncpuProbe) !usize {
        const rc = c.ring_buffer__consume(self.reader);
        if (rc < 0) return error.RingBufferFailed;
        return @intCast(rc);
    }

    /// Every stack read so far, in the order they came out of the ring.
    pub fn stacks(self: *const OncpuProbe) []const Stack {
        return self.sink.stacks[0..self.sink.len];
    }

    /// Records that were malformed or did not fit in our buffer: both should stay 0.
    pub fn problems(self: *const OncpuProbe) usize {
        return self.sink.malformed + self.sink.overflow;
    }

    /// The counters of the program, added up over all CPUs.
    pub fn totals(self: *OncpuProbe) !Totals {
        const ncpu: usize = @intCast(try sys.numPossibleCpus());
        const bytes = try self.allocator.alloc(u8, ncpu * @sizeOf(Slot));
        defer self.allocator.free(bytes);
        const key = std.mem.toBytes(@as(u32, 0));
        if (!try self.state.map.lookupPerCpu(&key, bytes)) return error.NotFound;
        var out = Totals{};
        for (0..ncpu) |i| {
            const slot = std.mem.bytesToValue(Slot, bytes[i * @sizeOf(Slot) ..][0..@sizeOf(Slot)]);
            out.walks += slot.walks;
            out.kernel_walks += slot.kernel_walks;
            out.sent += slot.sent;
            out.dropped += slot.dropped;
            out.repeats += slot.repeats;
            out.map_full += slot.map_full;
            for (slot.stops, 0..) |n, s| out.stops[s] += n;
        }
        return out;
    }

    /// Takes every entry out of the counts map and appends it to `out`. A stack that is sampled
    /// again afterwards starts a new entry and is sent through the ring again. Call it while
    /// sampling is paused: between reading a count and deleting its key, an increment from
    /// another CPU would be lost.
    pub fn drain(self: *OncpuProbe, allocator: std.mem.Allocator, out: *std.ArrayList(Drained)) !void {
        const counts = try m.TypedMap(CountKey, u64).init(self.counts.map);
        while (try counts.nextKey(null)) |key| {
            const value = try counts.lookup(key);
            _ = try counts.delete(key);
            if (value) |count| try out.append(allocator, .{ .key = key, .count = count });
        }
    }

    /// Appends the current cumulative count of every stack to `out`, without removing anything.
    /// Safe while sampling runs: counts only grow, and a key that appears or is missed during
    /// the walk is found by the next snapshot. The weight of a window is the difference between
    /// two snapshots.
    pub fn snapshot(self: *OncpuProbe, allocator: std.mem.Allocator, out: *std.ArrayList(Drained)) !void {
        const counts = try m.TypedMap(CountKey, u64).init(self.counts.map);
        var prev: ?CountKey = null;
        while (try counts.nextKey(prev)) |key| {
            prev = key;
            if (try counts.lookup(key)) |count| try out.append(allocator, .{ .key = key, .count = count });
        }
    }

    pub fn deinit(self: *OncpuProbe) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        if (self.events.len > 0) self.allocator.free(self.events);
        c.ring_buffer__free(self.reader);
        self.allocator.free(self.sink.stacks);
        self.allocator.destroy(self.sink);
        self.loader.deinit();
        self.target.map.deinit();
        self.rows.map.deinit();
        self.modules.map.deinit();
        self.procs.map.deinit();
        self.state.map.deinit();
        self.progs.map.deinit();
        self.ring.map.deinit();
        self.counts.map.deinit();
    }
};
