//! The kernel half of the CPU profiler: the sampling program (bpf/kernel/cpu.bpf.zig) loaded
//! into the kernel with its own maps, bound to the shared unwind maps.

const std = @import("std");
const assert = std.debug.assert;
const libbpf = @import("../bpf/libbpf.zig");
const loader = @import("../bpf/loader.zig");
const map_file = @import("../bpf/map.zig");
const Object = @import("../bpf/object.zig").Object;
const Program = @import("../bpf/program.zig").Program;
const cpu_wire = @import("../bpf/kernel/shared/cpu_wire.zig");
const Tables = @import("../unwind/tables.zig").Tables;
const log = @import("../log.zig").agent;

const Map = map_file.Map;
const TypedMap = map_file.TypedMap;
const Config = cpu_wire.Config;
const CountKey = cpu_wire.CountKey;
const WalkState = cpu_wire.WalkState;

/// The program's own maps, by the names it declares them under.
pub const MapName = enum { cpu_config, cpu_state, cpu_walk_next, cpu_counts, cpu_records };

const map_count = @typeInfo(MapName).@"enum".fields.len;
const unwind_map_count = @typeInfo(@import("../unwind/tables.zig").MapName).@"enum".fields.len;

/// The program's counters for the whole run, summed over the CPUs.
pub const Counters = struct {
    walks_completed: u64 = 0,
    walks_from_kernel: u64 = 0,
    walks_abandoned: u64 = 0,
    records_sent: u64 = 0,
    records_dropped: u64 = 0,
    stacks_repeated: u64 = 0,
    counts_insert_failed: u64 = 0,
    stop_counts: [cpu_wire.stop_reason_count]u64 = @splat(0),
};

pub const Sampler = struct {
    maps: std.EnumArray(MapName, Map),
    program: Program,
    /// One per possible CPU: the per-CPU state map returns one value for each.
    states: []WalkState,

    /// Loads the program. `tables` must outlive the sampler: the program reads its maps.
    pub fn init(sampler: *Sampler, gpa: std.mem.Allocator, tables: *const Tables) !void {
        const object = try Object.init(@embedFile("cpu_bpf"));

        // Both sides of each shared map must agree, or the program would read past its values.
        for (tables.bindings(), 0..) |binding, index| {
            try loader.map_check(&object, binding.name, &tables.maps.values[index]);
        }

        const cpu_possible_count = try libbpf.cpu_possible_count();
        sampler.* = .{ .maps = undefined, .program = undefined, .states = &.{} };
        sampler.states = try gpa.alloc(WalkState, cpu_possible_count);
        errdefer gpa.free(sampler.states);

        try maps_create(&object, &sampler.maps);
        errdefer for (&sampler.maps.values) |*map| map.deinit();

        var bindings: [map_count + unwind_map_count]loader.MapBinding = undefined;
        for (bindings[0..map_count], 0..) |*binding, index| {
            const name: MapName = @enumFromInt(index);
            binding.* = .{ .name = @tagName(name), .fd = sampler.maps.get(name).fd };
        }
        bindings[map_count..].* = tables.bindings();

        sampler.program = try loader.program_load(gpa, &object, .{
            .kind = .perf_event,
            .section = "perf_event/cpu_sample",
            .function = "cpu_sample",
            .maps = &bindings,
        });
        errdefer sampler.program.deinit();

        // Slot 0 of the program array is the program itself, so a walk can continue.
        const walk_next = try TypedMap(u32, u32).init(sampler.maps.getPtrConst(.cpu_walk_next));
        try walk_next.update(0, &@as(u32, @intCast(sampler.program.fd)));
        log.debug("cpu sampler loaded", .{
            .cpus_possible = cpu_possible_count,
            .counts_max = cpu_wire.counts_max,
            .ring_kib = cpu_wire.records_bytes / 1024,
        });
    }

    /// Call after every perf event that runs the program is closed.
    pub fn deinit(sampler: *Sampler, gpa: std.mem.Allocator) void {
        sampler.program.deinit();
        for (&sampler.maps.values) |*map| map.deinit();
        gpa.free(sampler.states);
        sampler.* = undefined;
    }

    pub fn config_write(sampler: *const Sampler, config: Config) !void {
        const map = try TypedMap(u32, Config).init(sampler.maps.getPtrConst(.cpu_config));
        try map.update(0, &config);
    }

    pub fn records_fd(sampler: *const Sampler) i32 {
        return sampler.maps.get(.cpu_records).fd;
    }

    /// The counters of the run so far, summed over the CPUs. Allocates nothing.
    pub fn counters_read(sampler: *const Sampler) !Counters {
        const key: u32 = 0;
        const found = try sampler.maps.getPtrConst(.cpu_state).lookup(
            std.mem.asBytes(&key),
            std.mem.sliceAsBytes(sampler.states),
        );
        // An array map has every key from creation.
        assert(found);

        var counters = Counters{};
        for (sampler.states) |*state| {
            counters.walks_completed += state.walks_completed;
            counters.walks_from_kernel += state.walks_from_kernel;
            counters.walks_abandoned += state.walks_abandoned;
            counters.records_sent += state.records_sent;
            counters.records_dropped += state.records_dropped;
            counters.stacks_repeated += state.stacks_repeated;
            counters.counts_insert_failed += state.counts_insert_failed;
            for (&counters.stop_counts, state.stop_counts) |*sum, count| sum.* += count;
        }
        return counters;
    }

    /// Moves the counts of every generation but `generation_current` out of the kernel, into
    /// `keys` and `values`, and returns how many there were. Two system calls, whatever the count.
    ///
    /// The program counts under the current generation only, so the older keys no longer
    /// change. A sample that read the generation just before it advanced can still land in an
    /// older key; if it lands after the read, its key stays and is drained next time.
    pub fn counts_drain(
        sampler: *const Sampler,
        keys: []CountKey,
        values: []u64,
        generation_current: u32,
    ) !u32 {
        assert(keys.len == cpu_wire.counts_max);
        assert(values.len == cpu_wire.counts_max);

        const counts = try TypedMap(CountKey, u64).init(sampler.maps.getPtrConst(.cpu_counts));
        const count_all = try counts.lookup_batch(keys, values);
        assert(count_all <= cpu_wire.counts_max);

        // Keep the older generations' entries, in place, at the front.
        var count_old: u32 = 0;
        for (keys[0..count_all], values[0..count_all]) |key, value| {
            if (key.generation == generation_current) continue;
            keys[count_old] = key;
            values[count_old] = value;
            count_old += 1;
        }
        try counts.delete_batch(keys[0..count_old]);
        return count_old;
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

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "the program's maps are declared as the agent expects them" {
    const object = try Object.init(@embedFile("cpu_bpf"));

    const counts = try object.map_definition("cpu_counts");
    try testing.expectEqual(@as(u32, @sizeOf(CountKey)), counts.key_size);
    try testing.expectEqual(@as(u32, @sizeOf(u64)), counts.value_size);
    try testing.expectEqual(cpu_wire.counts_max, counts.max_entries);

    const state = try object.map_definition("cpu_state");
    try testing.expectEqual(@as(u32, @sizeOf(WalkState)), state.value_size);

    const config = try object.map_definition("cpu_config");
    try testing.expectEqual(@as(u32, @sizeOf(Config)), config.value_size);

    const records = try object.map_definition("cpu_records");
    try testing.expectEqual(cpu_wire.records_bytes, records.max_entries);
}

test "init and deinit, and nothing is counted before a target is set (needs root)" {
    var tables: Tables = undefined;
    tables.init(testing.allocator) catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    defer tables.deinit(testing.allocator);

    var sampler: Sampler = undefined;
    try sampler.init(testing.allocator, &tables);
    defer sampler.deinit(testing.allocator);

    const counters = try sampler.counters_read();
    try testing.expectEqual(@as(u64, 0), counters.walks_completed);
    try testing.expectEqual(@as(u64, 0), counters.records_sent);

    // 384 KiB: on the heap, not the test's stack.
    const keys = try testing.allocator.alloc(CountKey, cpu_wire.counts_max);
    defer testing.allocator.free(keys);
    const values = try testing.allocator.alloc(u64, cpu_wire.counts_max);
    defer testing.allocator.free(values);
    try testing.expectEqual(@as(u32, 0), try sampler.counts_drain(keys, values, 0));
}
