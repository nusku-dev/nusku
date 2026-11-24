//! A function probe: an entry probe notes when each call starts, a return probe how long
//! it took. Calls are kept per thread, so recursion and threads time each call apart.

const helpers = @import("helpers.zig");
const wire = @import("shared/probe_wire.zig");

const map_lookup_elem = helpers.map_lookup_elem;
const map_update_elem = helpers.map_update_elem;
const map_delete_elem = helpers.map_delete_elem;
const ktime_get_ns = helpers.ktime_get_ns;
const get_current_pid_tgid = helpers.get_current_pid_tgid;

const MapDef = helpers.MapDef;
const MapType = helpers.MapType;
const Calls = wire.Calls;
const Config = wire.Config;
const Stats = wire.Stats;

export var probe_config: MapDef linksection(".maps") = .{
    .map_type = MapType.array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(Config),
    .max_entries = 1,
};

export var probe_calls: MapDef linksection(".maps") = .{
    .map_type = MapType.hash,
    .key_size = @sizeOf(u64),
    .value_size = @sizeOf(Calls),
    .max_entries = wire.threads_max,
};

export var probe_stats: MapDef linksection(".maps") = .{
    .map_type = MapType.percpu_array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(Stats),
    .max_entries = 1,
};

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };

inline fn ours(pid_tgid: u64) bool {
    var zero: u32 = 0;
    const config: *const Config = @ptrCast(@alignCast(map_lookup_elem(&probe_config, &zero) orelse return false));

    return config.tgid != 0 and @as(u32, @truncate(pid_tgid >> 32)) == config.tgid;
}

inline fn stats() ?*Stats {
    var zero: u32 = 0;
    return @ptrCast(@alignCast(map_lookup_elem(&probe_stats, &zero) orelse return null));
}

export fn probe_enter(context: *anyopaque) linksection("uprobe/probe_enter") c_int {
    _ = context;
    const pid_tgid = get_current_pid_tgid();
    if (!ours(pid_tgid)) return 0;
    const now = ktime_get_ns();
    const counted = stats() orelse return 0;
    counted.calls += 1;

    const found: ?*Calls = @ptrCast(@alignCast(map_lookup_elem(&probe_calls, &pid_tgid)));
    if (found) |calls| {
        const depth = calls.depth;
        if (depth < wire.depth_max) calls.started_ns[depth & (wire.depth_max - 1)] = now;
        calls.depth = depth + 1;
        return 0;
    }
    var fresh: Calls = undefined;
    fresh.depth = 1;
    fresh.pad = 0;
    inline for (&fresh.started_ns) |*started| started.* = 0;
    fresh.started_ns[0] = now;
    if (map_update_elem(&probe_calls, &pid_tgid, &fresh, helpers.update_no_exist) != 0) {
        counted.dropped += 1;
    }
    return 0;
}

export fn probe_return(context: *anyopaque) linksection("uretprobe/probe_return") c_int {
    _ = context;
    const pid_tgid = get_current_pid_tgid();
    if (!ours(pid_tgid)) return 0;
    const now = ktime_get_ns();
    const counted = stats() orelse return 0;

    const found: ?*Calls = @ptrCast(@alignCast(map_lookup_elem(&probe_calls, &pid_tgid)));
    const calls = found orelse {
        counted.unmatched += 1;
        return 0;
    };
    if (calls.depth == 0) {
        counted.unmatched += 1;
        return 0;
    }
    const depth = calls.depth - 1;
    calls.depth = depth;
    if (depth >= wire.depth_max) {
        counted.untimed += 1;
        return 0;
    }
    const started = calls.started_ns[depth & (wire.depth_max - 1)];
    if (depth == 0) _ = map_delete_elem(&probe_calls, &pid_tgid);
    const took = if (now > started) now - started else 0;
    counted.timed += 1;
    counted.total_ns += took;
    if (took > counted.max_ns) counted.max_ns = took;
    const bucket = wire.bucket_of(took);
    counted.histogram[bucket & (wire.buckets - 1)] += 1;
    return 0;
}
