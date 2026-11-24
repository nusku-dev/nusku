//! A function probe on one process: how often a function is called, and how long each call
//! takes, from an entry probe and a return probe.
const std = @import("std");
const assert = std.debug.assert;

const libbpf = @import("../bpf/libbpf.zig");
const loader = @import("../bpf/loader.zig");
const map_file = @import("../bpf/map.zig");
const Object = @import("../bpf/object.zig").Object;
const Program = @import("../bpf/program.zig").Program;
const PerfEvent = @import("../../os/perf_event.zig").PerfEvent;
const wire = @import("../kernel/shared/probe_wire.zig");
const log = @import("../../log.zig").agent;

const Map = map_file.Map;
const TypedMap = map_file.TypedMap;
const Stats = wire.Stats;

pub const buckets = wire.buckets;
pub const bucket_of = wire.bucket_of;

const MapName = enum {
    probe_config,
    probe_calls,
    probe_stats,
};

const map_count = @typeInfo(MapName).@"enum".fields.len;
const path_bytes_max = 4096;

pub const Options = struct {
    pid: u32,
    /// The file as the process maps it.
    path: []const u8,
    /// Where the function starts in that file.
    offset: u64,
};

/// Counted since the probe was attached.
pub const Totals = struct {
    calls: u64 = 0,
    timed: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    untimed: u64 = 0,
    unmatched: u64 = 0,
    dropped: u64 = 0,
    histogram: [buckets]u64 = @splat(0),
};

pub const Probe = struct {
    maps: std.EnumArray(MapName, Map),
    enter: Program,
    exit: Program,
    events: [2]PerfEvent,
    per_cpu: []Stats,

    pub fn init(probe: *Probe, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.pid > 0);
        if (options.path.len == 0 or options.path[0] != '/') return error.InvalidPath;

        const object = try Object.init(@embedFile("probe_bpf"));
        const cpu_num = try libbpf.cpu_possible_count();
        probe.per_cpu = try gpa.alloc(Stats, cpu_num);
        errdefer gpa.free(probe.per_cpu);

        try maps_create(&object, &probe.maps);
        errdefer for (&probe.maps.values) |*map| map.deinit();
        const config = try TypedMap(u32, wire.Config).init(probe.maps.getPtrConst(.probe_config));
        try config.update(0, &.{ .tgid = options.pid });

        var bindings: [map_count]loader.MapBinding = undefined;
        for (&bindings, 0..) |*binding, index| {
            const name: MapName = @enumFromInt(index);
            binding.* = .{ .name = @tagName(name), .fd = probe.maps.get(name).fd };
        }

        probe.enter = try loader.program_load(gpa, &object, .{
            .kind = .kprobe,
            .section = "uprobe/probe_enter",
            .function = "probe_enter",
            .maps = &bindings,
        });
        errdefer probe.enter.deinit();

        probe.exit = try loader.program_load(gpa, &object, .{
            .kind = .kprobe,
            .section = "uretprobe/probe_return",
            .function = "probe_return",
            .maps = &bindings,
        });
        errdefer probe.exit.deinit();

        try probe.attach(options);
        log.info("function probe attached", .{
            .pid = options.pid,
            .path = options.path,
            .offset = options.offset,
        });
    }

    pub fn deinit(probe: *Probe, gpa: std.mem.Allocator) void {
        for (&probe.events) |*event| event.deinit();
        probe.exit.deinit();
        probe.enter.deinit();
        for (&probe.maps.values) |*map| map.deinit();
        gpa.free(probe.per_cpu);
        probe.* = undefined;
    }

    pub fn read(probe: *const Probe) !Totals {
        const key: u32 = 0;
        const found = try probe.maps.getPtrConst(.probe_stats).lookup(
            std.mem.asBytes(&key),
            std.mem.sliceAsBytes(probe.per_cpu),
        );
        assert(found);
        var totals = Totals{};
        for (probe.per_cpu) |*cpu| {
            totals.calls += cpu.calls;
            totals.timed += cpu.timed;
            totals.total_ns += cpu.total_ns;
            totals.max_ns = @max(totals.max_ns, cpu.max_ns);
            totals.untimed += cpu.untimed;
            totals.unmatched += cpu.unmatched;
            totals.dropped += cpu.dropped;
            for (&totals.histogram, cpu.histogram) |*sum, count| sum.* += count;
        }
        return totals;
    }

    /// The return probe first: an entry seen without it would never be timed.
    fn attach(probe: *Probe, options: Options) !void {
        var buffer: [path_bytes_max + 32]u8 = undefined;
        const root = "/proc/{d}/root{s}";
        const path = std.fmt.bufPrintZ(&buffer, root, .{ options.pid, options.path }) catch return error.InvalidPath;
        probe.events[1] = try PerfEvent.uprobe_open(options.pid, path, options.offset, true);
        errdefer probe.events[1].deinit();
        probe.events[0] = try PerfEvent.uprobe_open(options.pid, path, options.offset, false);
        errdefer probe.events[0].deinit();
        try probe.events[1].program_attach(probe.exit.fd);
        try probe.events[0].program_attach(probe.enter.fd);
        try probe.events[1].enable();
        try probe.events[0].enable();
    }
};

fn maps_create(object: *const Object, maps: *std.EnumArray(MapName, Map)) !void {
    var created: u32 = 0;
    errdefer for (maps.values[0..created]) |*map| map.deinit();
    for (&maps.values, 0..) |*map, index| {
        const name: MapName = @enumFromInt(index);
        map.* = try loader.map_create(object, @tagName(name));
        created += 1;
    }
}

const testing = std.testing;

test "the probe's maps are declared as the agent expects them" {
    const object = try Object.init(@embedFile("probe_bpf"));
    const calls = try object.map_definition("probe_calls");
    try testing.expectEqual(@as(u32, @sizeOf(u64)), calls.key_size);
    try testing.expectEqual(@as(u32, @sizeOf(wire.Calls)), calls.value_size);
    const stats = try object.map_definition("probe_stats");
    try testing.expectEqual(@as(u32, @sizeOf(Stats)), stats.value_size);
}

fn probe_child(calls: u32, depth: u32) !Totals {
    const child_process = @import("../../testing/process.zig");
    const process_maps = @import("../../target/process_maps.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const address = @intFromPtr(&child_process.probed_function);
    const own = std.os.linux.getpid();
    const mappings = try process_maps.read(arena.allocator(), @intCast(own));
    const mapping = for (mappings) |found| {
        if (address >= found.start and address < found.end) break found;
    } else return error.NotMapped;

    const caller = try child_process.caller_spawn(calls, 2000, depth);
    var probe: Probe = undefined;
    probe.init(testing.allocator, .{
        .pid = caller.pid,
        .path = mapping.path,
        .offset = address - mapping.start + mapping.offset,
    }) catch |err| {
        child_process.child_reap(caller.pid);
        return err;
    };
    defer probe.deinit(testing.allocator);
    child_process.caller_start(caller);
    child_process.child_wait(caller.pid);
    return probe.read();
}

test "a function called a thousand times is counted and timed a thousand times (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const totals = try probe_child(1000, 1);
    var bucketed: u64 = 0;
    for (totals.histogram) |count| bucketed += count;
    std.debug.print("probe: {d} calls, {d} timed, mean {d} ns, max {d} ns\n", .{
        totals.calls,
        totals.timed,
        totals.total_ns / @max(totals.timed, 1),
        totals.max_ns,
    });
    try testing.expectEqual(@as(u64, 1000), totals.calls);
    try testing.expectEqual(@as(u64, 1000), totals.timed);
    try testing.expectEqual(@as(u64, 1000), bucketed);
    try testing.expectEqual(@as(u64, 0), totals.unmatched + totals.untimed + totals.dropped);
    try testing.expect(totals.total_ns >= 1000 * 1000);
    try testing.expect(totals.max_ns >= totals.total_ns / 1000);
}

test "a recursive function: each nested call is timed apart (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const shallow = try probe_child(100, 4);
    try testing.expectEqual(@as(u64, 400), shallow.calls);
    try testing.expectEqual(@as(u64, 400), shallow.timed);
    try testing.expectEqual(@as(u64, 0), shallow.unmatched + shallow.untimed);

    const deep = try probe_child(10, wire.depth_max + 4);
    try testing.expectEqual(@as(u64, 10 * (wire.depth_max + 4)), deep.calls);
    try testing.expectEqual(@as(u64, 10 * wire.depth_max), deep.timed);
    try testing.expectEqual(@as(u64, 10 * 4), deep.untimed);
}
