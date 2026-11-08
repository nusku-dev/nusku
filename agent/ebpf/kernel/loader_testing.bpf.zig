//! A small, independent program for testing the loader (bpf/loader.zig): three maps of three
//! kinds, and code that refers to all of them. It is not used to profile anything.

const helpers = @import("helpers.zig");

const MapDef = helpers.MapDef;
const MapType = helpers.MapType;

const stack_depth_max = 127;
const entries_max = 16384;

/// One counter per (process, user stack, kernel stack).
const StackKey = extern struct {
    tgid: u32,
    user_stack_id: i32,
    kernel_stack_id: i32,
};

/// Slot 0 holds the tgid to count. 0 counts nothing.
export var target_pid: MapDef linksection(".maps") = .{
    .map_type = MapType.array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(u32),
    .max_entries = 1,
};

/// Stack id -> up to `stack_depth_max` return addresses.
export var stacks: MapDef linksection(".maps") = .{
    .map_type = MapType.stack_trace,
    .key_size = @sizeOf(u32),
    .value_size = stack_depth_max * @sizeOf(u64),
    .max_entries = entries_max,
};

/// StackKey -> number of samples.
export var counts: MapDef linksection(".maps") = .{
    .map_type = MapType.hash,
    .key_size = @sizeOf(StackKey),
    .value_size = @sizeOf(u64),
    .max_entries = entries_max,
};

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };

export fn count_stack(context: *anyopaque) linksection("perf_event") c_int {
    var zero: u32 = 0;
    const target_pointer = helpers.map_lookup_elem(&target_pid, &zero) orelse return 0;
    const target: *const u32 = @ptrCast(@alignCast(target_pointer));
    if (target.* == 0) return 0;

    const tgid: u32 = @truncate(helpers.get_current_pid_tgid() >> 32);
    if (tgid != target.*) return 0;

    const user_flags = helpers.stack_user | helpers.stack_fast_compare;
    var key: StackKey = undefined;
    key.tgid = tgid;
    key.user_stack_id = @truncate(helpers.get_stackid(context, &stacks, user_flags));
    const kernel_flags = helpers.stack_fast_compare;
    key.kernel_stack_id = @truncate(helpers.get_stackid(context, &stacks, kernel_flags));

    if (helpers.map_lookup_elem(&counts, &key)) |count_pointer| {
        const count: *u64 = @ptrCast(@alignCast(count_pointer));
        _ = @atomicRmw(u64, count, .Add, 1, .monotonic);
    } else {
        var one: u64 = 1;
        _ = helpers.map_update_elem(&counts, &key, &one, helpers.update_no_exist);
    }
    return 0;
}
