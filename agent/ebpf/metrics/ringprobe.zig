//! Harness for `ringProbe` (step 1e-c1): samples one process on every CPU, with the program
//! sending a record per sample through a ring buffer, and reads the records back with libbpf's
//! ring buffer reader.
const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const c = @import("../libc/import.zig").clibs;
const TypedMap = @import("../loader/map.zig").TypedMap;

pub const max_cpus = 256;

/// What the program sends for every sample. Must match `RingRecord` in oncpu.ebpf.zig.
pub const Record = extern struct { seq: u64, pc: u64, tgid: u32, cpu: u32 };

/// One per CPU, kept by the program. Must match `RingSlot` in oncpu.ebpf.zig.
pub const Counters = extern struct { seq: u64, sent: u64, dropped: u64 };

comptime {
    if (@sizeOf(Record) != 24 or @sizeOf(Counters) != 24) @compileError("ring layouts changed: update oncpu.ebpf.zig too");
}

/// Where the callback puts what it reads. It lives on the heap because libbpf keeps the pointer.
const Sink = struct {
    records: []Record,
    len: usize = 0,
    wrong_size: usize = 0,
    overflow: usize = 0,
};

fn onRecord(ctx: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    const sink: *Sink = @ptrCast(@alignCast(ctx.?));
    if (size != @sizeOf(Record)) {
        sink.wrong_size += 1;
        return 0;
    }
    if (sink.len == sink.records.len) {
        sink.overflow += 1;
        return 0;
    }
    const record: *align(1) const Record = @ptrCast(data.?);
    sink.records[sink.len] = record.*;
    sink.len += 1;
    return 0;
}

pub const RingProbe = struct {
    allocator: std.mem.Allocator,
    loader: l.Loader,
    target: l.MapRef,
    ring: l.MapRef,
    debug: l.MapRef,
    counters: TypedMap(u32, Counters),
    reader: *c.struct_ring_buffer,
    sink: *Sink,
    program_fd: c_int,
    events: []perf.Event,
    attached: usize,

    /// Creates the maps and loads the program. Nothing is sampled until `begin`.
    pub fn init(allocator: std.mem.Allocator) !RingProbe {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));
        var loader = l.Loader.init(allocator, elf);
        errdefer loader.deinit();
        var target = try loader.createMap("target_pid");
        errdefer target.map.deinit();
        var ring = try loader.createMap("ring");
        errdefer ring.map.deinit();
        var debug = try loader.createMap("ring_debug");
        errdefer debug.map.deinit();

        var maps: [3]l.MapRef = .{ target, ring, debug };
        const program_fd = try loader.load(.perf_event, "perf_event/ring", "ringProbe", maps[0..3]);

        const allRecords = try allocator.alloc(Record, 65536);
        errdefer allocator.free(allRecords);
        const sink = try allocator.create(Sink);
        errdefer allocator.destroy(sink);
        sink.* = .{ .records = allRecords };
        const reader = c.ring_buffer__new(ring.map.fd, onRecord, sink, null) orelse return error.RingBufferFailed;
        errdefer c.ring_buffer__free(reader);

        return .{
            .allocator = allocator,
            .loader = loader,
            .target = target,
            .ring = ring,
            .debug = debug,
            .counters = try TypedMap(u32, Counters).init(debug.map),
            .reader = reader,
            .sink = sink,
            .program_fd = program_fd,
            .events = &.{},
            .attached = 0,
        };
    }

    /// Samples of `pid` are recorded from now on (0 stops recording).
    pub fn setTarget(self: *RingProbe, pid: u32) !void {
        const index = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(pid);
        try self.target.map.update(&index, &value);
    }

    /// Starts sampling `pid` at `hz` on every CPU.
    pub fn begin(self: *RingProbe, pid: u32, hz: u32) !void {
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
    pub fn pause(self: *RingProbe) !void {
        try self.setTarget(0);
        sys.sleepMs(5);
    }

    /// Reads everything that is in the ring now. Returns how many records it read.
    pub fn consume(self: *RingProbe) !usize {
        const rc = c.ring_buffer__consume(self.reader);
        if (rc < 0) return error.RingBufferFailed;
        return @intCast(rc);
    }

    /// Every record read so far, in the order they came out of the ring.
    pub fn records(self: *const RingProbe) []const Record {
        return self.sink.records[0..self.sink.len];
    }

    /// Records of the wrong size, or that did not fit in our buffer: both should stay 0.
    pub fn problems(self: *const RingProbe) usize {
        return self.sink.wrong_size + self.sink.overflow;
    }

    pub fn counter(self: *RingProbe, cpu: u32) !Counters {
        return (try self.counters.lookup(cpu)) orelse error.NotFound;
    }

    pub fn deinit(self: *RingProbe) void {
        for (self.events[0..self.attached]) |*e| e.deinit();
        if (self.events.len > 0) self.allocator.free(self.events);
        c.ring_buffer__free(self.reader);
        self.allocator.free(self.sink.records);
        self.allocator.destroy(self.sink);
        self.loader.deinit();
        self.target.map.deinit();
        self.ring.map.deinit();
        self.debug.map.deinit();
    }
};
