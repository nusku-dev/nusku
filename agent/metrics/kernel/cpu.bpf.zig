//! The on-CPU sampler, run by a CPU-clock perf event on every CPU.

const helpers = @import("helpers.zig");
const cpu_wire = @import("shared/cpu_wire.zig");
const unwind_wire = @import("unwind_wire");

const map_lookup_elem = helpers.map_lookup_elem;
const map_update_elem = helpers.map_update_elem;
const tail_call = helpers.tail_call;
const get_current_pid_tgid = helpers.get_current_pid_tgid;
const get_current_task_btf = helpers.get_current_task_btf;
const task_pt_regs = helpers.task_pt_regs;
const probe_read_user = helpers.probe_read_user;
const get_stack = helpers.get_stack;
const ringbuf_output = helpers.ringbuf_output;

const MapDef = helpers.MapDef;
const MapType = helpers.MapType;
const Registers = helpers.Registers;

const Config = cpu_wire.Config;
const CountKey = cpu_wire.CountKey;
const RecordHeader = cpu_wire.RecordHeader;
const StopReason = cpu_wire.StopReason;
const WalkState = cpu_wire.WalkState;

const Mapping = unwind_wire.Mapping;
const Module = unwind_wire.Module;
const ProcessEntry = unwind_wire.ProcessEntry;
const Row = unwind_wire.Row;

const user_frames_max = cpu_wire.user_frames_max;
const kernel_frames_max = cpu_wire.kernel_frames_max;
const frames_per_run = cpu_wire.frames_per_run;
const stop_reason_count = cpu_wire.stop_reason_count;
const rows_max = unwind_wire.rows_max;
const modules_max = unwind_wire.modules_max;
const mappings_max = unwind_wire.mappings_max;
const module_none = unwind_wire.module_none;

const cfa_none = @intFromEnum(unwind_wire.CfaType.none);
const cfa_rsp = @intFromEnum(unwind_wire.CfaType.rsp);
const cfa_rbp = @intFromEnum(unwind_wire.CfaType.rbp);
const cfa_plt = @intFromEnum(unwind_wire.CfaType.plt);
const cfa_end = @intFromEnum(unwind_wire.CfaType.end);
const rbp_same = @intFromEnum(unwind_wire.RbpType.same);
const rbp_saved = @intFromEnum(unwind_wire.RbpType.saved);

const syscall_instruction_tail: u64 = 0x050f;

export var cpu_config: MapDef linksection(".maps") = .{
    .map_type = MapType.array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(Config),
    .max_entries = 1,
};

export var cpu_state: MapDef linksection(".maps") = .{
    .map_type = MapType.percpu_array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(WalkState),
    .max_entries = 1,
};

export var cpu_walk_next: MapDef linksection(".maps") = .{
    .map_type = MapType.prog_array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(u32),
    .max_entries = 1,
};

export var cpu_counts: MapDef linksection(".maps") = .{
    .map_type = MapType.hash,
    .key_size = @sizeOf(CountKey),
    .value_size = @sizeOf(u64),
    .max_entries = cpu_wire.counts_max,
};

export var cpu_records: MapDef linksection(".maps") = .{
    .map_type = MapType.ringbuf,
    .key_size = 0,
    .value_size = 0,
    .max_entries = cpu_wire.records_bytes,
};

export var unwind_rows: MapDef linksection(".maps") = .{
    .map_type = MapType.array,
    .key_size = @sizeOf(u32),
    .value_size = rows_max * @sizeOf(Row),
    .max_entries = 1,
};

export var unwind_modules: MapDef linksection(".maps") = .{
    .map_type = MapType.array,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(Module),
    .max_entries = modules_max,
};

export var unwind_procs: MapDef linksection(".maps") = .{
    .map_type = MapType.hash,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(ProcessEntry),
    .max_entries = unwind_wire.processes_max,
};

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };

export fn cpu_sample(context: *anyopaque) linksection("perf_event/cpu_sample") c_int {
    var zero: u32 = 0;
    const state_pointer = map_lookup_elem(&cpu_state, &zero) orelse return 0;
    const state: *WalkState = @ptrCast(@alignCast(state_pointer));

    const pid_tgid = get_current_pid_tgid();
    const tgid: u32 = @truncate(pid_tgid >> 32);

    if (state.walk_in_progress != 0) {
        if (state.walk_pid_tgid != pid_tgid) {
            state.walks_abandoned += 1;
            state.walk_in_progress = 0;
        }
    }

    if (state.walk_in_progress == 0) {
        if (!sample_is_target(tgid)) return 0;
        if (!walk_begin(state, context, pid_tgid)) return 0;
    }

    const stop = walk_run(state, tgid);
    if (stop != .none) {
        walk_finish(state, context, tgid, stop);
        return 0;
    }

    _ = tail_call(context, &cpu_walk_next, 0);

    // Reached only when the tail call failed.
    walk_finish(state, context, tgid, .tail_call_failed);
    return 0;
}

inline fn sample_is_target(tgid: u32) bool {
    var zero: u32 = 0;
    const config_pointer = map_lookup_elem(&cpu_config, &zero) orelse return false;
    const config: *const Config = @ptrCast(@alignCast(config_pointer));
    if (config.tgid == 0) return false;
    return config.tgid == tgid;
}

inline fn walk_begin(state: *WalkState, context: *anyopaque, pid_tgid: u64) bool {
    const task = get_current_task_btf() orelse return false;
    const registers_pointer = task_pt_regs(task) orelse return false;
    const registers: *const Registers = @ptrCast(@alignCast(registers_pointer));
    const sampled: *const Registers = @ptrCast(@alignCast(context));

    const sampled_in_user_mode = (sampled.cs & 3) == 3;
    const leaf_is_return = !sampled_in_user_mode and follows_syscall(registers.ip);

    state.walk_in_progress = 1;
    state.walk_pid_tgid = pid_tgid;
    state.pc = registers.ip;
    state.sp = registers.sp;
    state.bp = registers.bp;
    state.pc_is_leaf = if (leaf_is_return) 0 else 1;
    state.leaf_is_return = if (leaf_is_return) 1 else 0;
    state.frame_count = 0;
    state.frame_pointer_steps = 0;
    state.stack_hash = 0;

    var flags: u8 = 0;
    if (leaf_is_return) flags |= cpu_wire.record_flag_leaf_is_return;
    if (!sampled_in_user_mode) flags |= cpu_wire.record_flag_kernel_mode;
    state.record.flags = flags;

    if (!sampled_in_user_mode) state.walks_from_kernel += 1;
    return true;
}

inline fn follows_syscall(ip: u64) bool {
    if (ip < 8) return false;
    var preceding: u64 = 0;
    _ = probe_read_user(&preceding, @sizeOf(u64), ip - 8);
    return (preceding >> 48) == syscall_instruction_tail;
}

inline fn walk_run(state: *WalkState, tgid: u32) StopReason {
    var tgid_key = tgid;
    const process_pointer = map_lookup_elem(&unwind_procs, &tgid_key) orelse {
        if (state.frame_count != 0) return .invalid_stack;
        frame_push(state, 0, state.pc);
        return .no_mapping;
    };
    const process: *const ProcessEntry = @ptrCast(@alignCast(process_pointer));

    var frame_index: u32 = 0;
    while (frame_index < frames_per_run) : (frame_index += 1) {
        const count = state.frame_count;
        if (count >= user_frames_max) return .truncated;

        const pc = state.pc;
        const sp = state.sp;
        const bp = state.bp;

        const lookup_pc = if (state.pc_is_leaf != 0) pc else pc -% 1;
        const found: RowLookup = @call(.always_inline, row_find, .{ process, lookup_pc });

        if (found.status == .no_mapping) {
            if (count != 0) return .invalid_stack;
            frame_push(state, 0, pc);
            return .no_mapping;
        }
        frame_push(state, count, pc);

        const caller = frame_caller(found, pc, sp, bp);
        if (caller.stop != .none) return caller.stop;
        if (caller.pc == 0) return .end;
        if (caller.sp <= sp) return .stack_pointer_stuck;
        if (caller.used_frame_pointer) state.frame_pointer_steps += 1;

        state.pc = caller.pc;
        state.sp = caller.sp;
        state.bp = caller.bp;
        state.pc_is_leaf = 0;
    }
    return .none;
}

inline fn frame_push(state: *WalkState, index: u64, pc: u64) void {
    if (index >= user_frames_max) return; // The callers checked; the verifier wants it here.
    state.stack_frames[index] = pc;
    state.frame_count = index + 1;
    state.stack_hash = stack_hash_mix(state.stack_hash ^ pc);
}

const Caller = struct {
    stop: StopReason,
    pc: u64,
    sp: u64,
    bp: u64,
    used_frame_pointer: bool,
};

inline fn frame_caller(found: RowLookup, pc: u64, sp: u64, bp: u64) Caller {
    var caller = Caller{ .stop = .none, .pc = 0, .sp = 0, .bp = 0, .used_frame_pointer = false };

    if (found.status == .found) {
        const unwound: UnwindResult =
            @call(.always_inline, frame_unwind, .{ found.row, pc, sp, bp });
        switch (unwound.status) {
            .caller => {
                caller.pc = unwound.pc;
                caller.sp = unwound.sp;
                caller.bp = unwound.bp;
            },
            .end => caller.stop = .end,
            .read_failed => caller.stop = .stack_read_failed,
            .unsupported => caller.stop = .unsupported_unwind,
        }
        return caller;
    }

    caller = frame_pointer_unwind(sp, bp);
    caller.used_frame_pointer = true;
    return caller;
}

inline fn stack_hash_mix(value: u64) u64 {
    var mixed = value;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

inline fn walk_finish(state: *WalkState, context: *anyopaque, tgid: u32, stop: StopReason) void {
    state.walk_in_progress = 0;
    state.walks_completed += 1;

    const stop_index: u64 = @intFromEnum(stop);
    if (stop_index < stop_reason_count) state.stop_counts[stop_index] += 1;

    var user_frame_count = state.frame_count;
    if (user_frame_count > user_frames_max) user_frame_count = user_frames_max;
    state.record.user_frame_count = @truncate(user_frame_count);

    var stack_hash = state.stack_hash;
    var kernel_frame_count: u64 = 0;
    if ((state.record.flags & cpu_wire.record_flag_kernel_mode) != 0) {
        kernel_frame_count = kernel_frames_append(state, context, user_frame_count, &stack_hash);
    }
    state.record.kernel_frame_count = @truncate(kernel_frame_count);

    const identity_bits = (stop_index << 1) | state.leaf_is_return;
    state.record.stack_hash = stack_hash_mix(stack_hash ^ identity_bits);
    state.record.tgid = tgid;
    state.record.stop_reason = @intFromEnum(stop);

    const record_size =
        @sizeOf(RecordHeader) + (user_frame_count + kernel_frame_count) * @sizeOf(u64);
    stack_count(state, tgid, record_size);
}

inline fn kernel_frames_append(
    state: *WalkState,
    context: *anyopaque,
    user_frame_count: u64,
    stack_hash: *u64,
) u64 {
    const bytes_written = get_stack(
        context,
        &state.stack_frames[user_frame_count],
        kernel_frames_max * @sizeOf(u64),
        0,
    );
    if (bytes_written <= 0) return 0;

    var kernel_frame_count: u64 = @as(u64, @intCast(bytes_written)) / @sizeOf(u64);
    if (kernel_frame_count > kernel_frames_max) kernel_frame_count = kernel_frames_max;

    var index: u64 = 0;
    while (index < kernel_frame_count) : (index += 1) {
        stack_hash.* = stack_hash_mix(stack_hash.* ^ state.stack_frames[user_frame_count + index]);
    }
    if (kernel_frame_count == kernel_frames_max) {
        state.record.flags |= cpu_wire.record_flag_kernel_truncated;
    }
    return kernel_frame_count;
}

inline fn stack_count(state: *WalkState, tgid: u32, record_size: u64) void {
    var zero: u32 = 0;
    const config_pointer = map_lookup_elem(&cpu_config, &zero) orelse return;
    const config: *const Config = @ptrCast(@alignCast(config_pointer));

    const key = CountKey{
        .stack_hash = state.record.stack_hash,
        .tgid = tgid,
        .generation = config.generation,
    };

    if (map_lookup_elem(&cpu_counts, &key)) |count| {
        counter_increment(count);
        state.stacks_repeated += 1;
        return;
    }

    if (ringbuf_output(&cpu_records, &state.record, record_size, helpers.ringbuf_no_wakeup) != 0) {
        state.records_dropped += 1;
        return;
    }
    state.records_sent += 1;

    var count_first: u64 = 1;
    if (map_update_elem(&cpu_counts, &key, &count_first, helpers.update_no_exist) != 0) {
        if (map_lookup_elem(&cpu_counts, &key)) |count| {
            counter_increment(count);
        } else {
            state.counts_insert_failed += 1;
        }
    }
}

inline fn counter_increment(counter: *anyopaque) void {
    _ = @atomicRmw(u64, @as(*u64, @ptrCast(@alignCast(counter))), .Add, 1, .monotonic);
}

const RowStatus = enum(u8) {
    found,
    no_mapping,
    no_module,
    no_rule,
    invalid_table,
};

const RowLookup = struct {
    status: RowStatus,
    row: Row,
};

const row_zero = Row{
    .pc = 0,
    .cfa_offset = 0,
    .cfa_type = cfa_none,
    .rbp_type = rbp_same,
    .rbp_offset = 0,
};

fn row_find(process: *const ProcessEntry, ip: u64) RowLookup {
    var result = RowLookup{ .status = .no_mapping, .row = row_zero };

    const mapping_index = mapping_search(process, ip) orelse return result;
    if (mapping_index >= mappings_max) return result;
    const mapping: *const Mapping = &process.mappings[mapping_index];
    if (ip < mapping.start) return result;
    if (ip >= mapping.end) return result;

    result.status = .no_module;
    if (mapping.module == module_none) return result;
    if (mapping.module >= modules_max) return result;

    result.status = .no_rule;
    if (ip < mapping.bias) return result;
    const file_address = ip - mapping.bias;

    var module_key = mapping.module;
    const module_pointer = map_lookup_elem(&unwind_modules, &module_key) orelse {
        result.status = .no_module;
        return result;
    };
    const module: *const Module = @ptrCast(@alignCast(module_pointer));
    if (file_address < module.base) return result;
    const relative = file_address - module.base;
    if (relative >= module.end) return result;
    if (module.row_count == 0) return result;

    result.status = .invalid_table;
    if (module.row_start >= rows_max) return result;
    if (module.row_count > rows_max - module.row_start) return result;

    var zero: u32 = 0;
    const rows_pointer = map_lookup_elem(&unwind_rows, &zero) orelse return result;
    const rows: *const [rows_max]Row = @ptrCast(@alignCast(rows_pointer));

    result.status = .no_rule;
    const row_index = row_search(rows, module.row_start, module.row_count, relative) orelse
        return result;
    if (row_index >= rows_max) return result;
    const row = &rows[row_index];
    if (@as(u64, row.pc) > relative) return result;
    if (row.cfa_type == cfa_none) return result;

    result.status = .found;
    result.row = row.*;
    return result;
}

inline fn mapping_search(process: *const ProcessEntry, ip: u64) ?u32 {
    if (process.count == 0) return null;
    if (process.count > mappings_max) return null;

    var low: u32 = 0;
    var high: u32 = process.count;
    var steps: u32 = 0;
    while (low < high and steps < unwind_wire.mapping_search_steps_max) : (steps += 1) {
        const middle = low + (high - low) / 2;
        if (middle >= mappings_max) break;
        if (process.mappings[middle].start <= ip) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < high) return null;
    if (low == 0) return null;
    return low - 1;
}

inline fn row_search(
    rows: *const [rows_max]Row,
    row_start: u32,
    row_count: u32,
    relative: u64,
) ?u32 {
    var low: u32 = 0;
    var high: u32 = row_count;
    var steps: u32 = 0;
    while (low < high and steps < unwind_wire.row_search_steps_max) : (steps += 1) {
        const middle = low + (high - low) / 2;
        const row_index = row_start + middle;
        if (row_index >= rows_max) break;
        if (@as(u64, rows[row_index].pc) <= relative) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < high) return null;
    if (low == 0) return null;
    return row_start + (low - 1);
}

const UnwindStatus = enum(u8) { caller, end, unsupported, read_failed };

const UnwindResult = struct {
    status: UnwindStatus,
    pc: u64,
    sp: u64,
    bp: u64,
};

fn frame_unwind(row: Row, ip: u64, sp: u64, bp: u64) UnwindResult {
    var result = UnwindResult{ .status = .unsupported, .pc = 0, .sp = 0, .bp = 0 };

    var cfa: u64 = 0;
    switch (row.cfa_type) {
        cfa_rsp => {
            if (!offset_apply(sp, row.cfa_offset, &cfa)) {
                result.status = .read_failed;
                return result;
            }
        },
        cfa_rbp => {
            if (!offset_apply(bp, row.cfa_offset, &cfa)) {
                result.status = .read_failed;
                return result;
            }
        },
        cfa_plt => {
            if (row.cfa_offset < 0 or row.cfa_offset > 15) return result;
            const pushed: i64 = if ((ip & 15) >= @as(u64, @intCast(row.cfa_offset))) 8 else 0;
            if (!offset_apply(sp, 8 + pushed, &cfa)) {
                result.status = .read_failed;
                return result;
            }
        },
        cfa_end => {
            result.status = .end;
            return result;
        },
        else => return result,
    }

    if (cfa < 8) {
        result.status = .read_failed;
        return result;
    }
    var return_address: u64 = 0;
    if (probe_read_user(&return_address, @sizeOf(u64), cfa - 8) != 0) {
        result.status = .read_failed;
        return result;
    }

    var caller_bp = bp;
    if (row.rbp_type == rbp_saved) {
        var saved_bp_address: u64 = 0;
        if (!offset_apply(cfa, row.rbp_offset, &saved_bp_address)) {
            result.status = .read_failed;
            return result;
        }
        if (saved_bp_address >= sp) {
            if (probe_read_user(&caller_bp, @sizeOf(u64), saved_bp_address) != 0) {
                result.status = .read_failed;
                return result;
            }
        }
    } else {
        if (row.rbp_type != rbp_same) return result;
    }

    result.status = .caller;
    result.pc = return_address;
    result.sp = cfa;
    result.bp = caller_bp;
    return result;
}

fn offset_apply(address: u64, offset: i64, result: *u64) bool {
    if (offset >= 0) {
        const amount: u64 = @intCast(offset);
        if (address > ~@as(u64, 0) - amount) return false;
        result.* = address + amount;
        return true;
    }
    const amount: u64 = @intCast(-offset);
    if (address < amount) return false;
    result.* = address - amount;
    return true;
}

inline fn frame_pointer_unwind(sp: u64, bp: u64) Caller {
    var caller = Caller{ .stop = .none, .pc = 0, .sp = 0, .bp = 0, .used_frame_pointer = true };

    if (bp == 0) {
        caller.stop = .end;
        return caller;
    }
    if (bp < sp or bp % 8 != 0 or bp > ~@as(u64, 0) - 16) {
        caller.stop = .invalid_frame_pointer;
        return caller;
    }

    var saved_frame: [2]u64 = undefined;
    if (probe_read_user(&saved_frame, @sizeOf([2]u64), bp) != 0) {
        caller.stop = .stack_read_failed;
        return caller;
    }

    const caller_bp = saved_frame[0];
    if (caller_bp != 0) {
        if (caller_bp <= bp or caller_bp % 8 != 0) {
            caller.stop = .invalid_frame_pointer;
            return caller;
        }
    }
    caller.pc = saved_frame[1];
    caller.sp = bp + 16;
    caller.bp = caller_bp;
    return caller;
}
