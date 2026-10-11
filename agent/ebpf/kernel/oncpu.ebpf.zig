const BPF = @import("bpf.zig").BPF;
// Kernel side of the on-CPU profiler: runs on every perf_even sample (99 Hz per CPU)

// -- kernel helpers --
// A helper is called by number (BPF_FUNC_* in linux/bpf.h)
const bpf_map_lookup_elem: *align(1) const fn (*const anyopaque, *const anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(BPF.MAP.LOOKUP_ELEM);
const bpf_get_stackid: *align(1) const fn (*anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.STACKID);
const bpf_get_current_pid_tgid: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(BPF.GET.CURRENT_PID_TGID);
const bpf_map_update_elem: *align(1) const fn (*const anyopaque, *const anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(BPF.MAP.UPDATE_ELEM);

/// each stack holds up to 127 addresses, each 8 bytes (64-bit)
const MAX_STACK_DEPTH = 127;

///allows up to 16,384 stack entries.
const MAX_ENTRIES = 16384;

// -- maps --
// The loader reads these 16 bytes straight out of the .maps section and creates the map

const MapDef = extern struct {
    /// what kind of map to create.
    map_type: u32,
    /// how many bytes each key occupies.
    key_size: u32,
    /// how many bytes each value occupies.
    value_size: u32,
    /// the maximum number of entries.
    max_entries: u32,
};

/// One counter per (process, user stack, kernel stack). Userspace uses the same layout
const StackKey = extern struct {
    /// which process was running?
    tgid: u32,
    /// which application call stack was active?
    user_stack_id: i32,
    /// which kernel call stack was active?
    kernel_stack_id: i32,
};

/// Slot 0 holds the tgid to profile; 0 means "profile nothing"
/// Holds the PID we want to profile
export var target_pid: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

/// stack id -> up to 127 return addresses
/// Stores stack addresses, indexed by stack ID
export var stacks: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.STACK_TRACE,
    // Each stack ID is a 4-byte integer
    .key_size = 4,
    // 127 × 8 = 1016 bytes per stack.
    .value_size = MAX_STACK_DEPTH * 8,
    .max_entries = MAX_ENTRIES,
};

/// StackKey -> number of samples
/// Associates each unique StackKey with its sample count
export var counts: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = @sizeOf(StackKey),
    .value_size = 8,
    .max_entries = MAX_ENTRIES,
};

/// save each unique stack once, then count how many samples match it.
/// attach it on perf_even
export fn onCpusample(ctx: *anyopaque) linksection("perf_event") c_int {
    var zero: u32 = 0;

    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;

    // tgid is the process ID associated with the current BPF sample.
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var key: StackKey = undefined;
    key.tgid = tgid;
    key.user_stack_id = @truncate(bpf_get_stackid(ctx, &stacks, BPF.F.USER_STACK | BPF.F.FAST_STACK_CMP));
    key.kernel_stack_id = @truncate(bpf_get_stackid(ctx, &stacks, BPF.F.FAST_STACK_CMP));

    // increment the sample count if this stack has been seen before or create a new entry if it hasn't
    if (bpf_map_lookup_elem(&counts, &key)) |p| {
        const count: *u64 = @ptrCast(@alignCast(p));
        _ = @atomicRmw(u64, count, .Add, 1, .monotonic);
    } else {
        var one: u64 = 1;
        _ = bpf_map_update_elem(&counts, &key, &one, BPF.NOEXIST);
    }

    return 0;
}

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };
