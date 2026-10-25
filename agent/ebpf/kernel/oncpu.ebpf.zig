const bpf = @import("bpf.zig");
const stack_record = @import("shared/stack_record.zig");

const BPF = bpf.BPF;
const MapDef = bpf.MapDef;

const MAX_STACK_FRAMES = stack_record.MAX_STACK_FRAMES;
const MAX_KERNEL_STACK_FRAMES = stack_record.MAX_KERNEL_STACK_FRAMES;

const bpf_map_lookup_elem = BPF.MAP.lookup_elem;
const bpf_get_current_pid_tgid = BPF.GET.current_pid_tgid;
const bpf_get_current_task_btf = BPF.GET.current_task_btf;
const bpf_task_pt_regs = BPF.task_pt_regs;
const bpf_probe_read_user = BPF.probe_read_user;
const bpf_get_stack = BPF.GET.stack;
const bpf_tail_call = BPF.tail_call;
const bpf_ringbuf_output = BPF.ringbuf_output;
const bpf_map_update_elem = BPF.MAP.update_elem;

// Lookup results.
const ROW_FOUND: u8 = 0;
const ROW_NO_PROCESS: u8 = 1;
const ROW_NO_MAPPING: u8 = 2;
const ROW_NO_MODULE: u8 = 3;
const ROW_NO_RULE: u8 = 4;
const ROW_INVALID_TABLE: u8 = 5;

// Stop reasons. Keep the numeric values consistent with compactwalk.zig.
const STOP_END = 1;
const STOP_TRUNCATED = 2;
const STOP_NO_MODULE_MAPPING = 3;
const STOP_NO_FUNCTION_INFO = 4;
const STOP_UNSUPPORTED_UNWIND = 5;
const STOP_STACK_READ_FAILED = 6;
const STOP_STACK_POINTER_STUCK = 7;
const STOP_INVALID_STACK = 8;
const STOP_INVALID_FRAME_POINTER = 9;
const STOP_TAIL_CALL_FAILED = 10;

/// Maximum mappings stored for one process
const MAX_MAPPINGS = 128;
/// Special value meaning a mapping has no associated unwind-table module
const NO_MODULE: u32 = 0xffff_ffff;
/// Maximum iterations in the mapping binary search
const MAX_MAPPING_STEPS = 8;
/// Maximum iterations in the row binary search
const MAX_ROW_STEPS = 19;
/// Maximum number of unwind rows stored in the row map
const MAX_ROWS = 262144;
/// Maximum module entries in the module map
const MAX_MODULES = 256;
/// Maximum processes tracked in the process map
const MAX_PROCESSES = 1024;

const RING_BUFFER_BYTES = 256 * 1024;

// Results from recovering the caller's registers.
const UNWIND_CALLER: u8 = 0;
const UNWIND_END: u8 = 1;
const UNWIND_NO_RULE: u8 = 2;
const UNWIND_UNSUPPORTED: u8 = 3;
const UNWIND_READ_FAILED: u8 = 4;

const FRAMES_PER_BATCH = 4;
const STACK_RECORD_HEADER_BYTES = 16;

// a structure that stores the values of CPU registers on x86-64 Linux
const CpuRegisters = extern struct { r15: u64, r14: u64, r13: u64, r12: u64, bp: u64, bx: u64, r11: u64, r10: u64, r9: u64, r8: u64, ax: u64, cx: u64, dx: u64, si: u64, di: u64, orig_ax: u64, ip: u64, cs: u64, flags: u64, sp: u64, ss: u64 };

const OnCpuStackState = stack_record.OnCpuStackState;
const StackCountKey = stack_record.StackCountKey;
/// one unwind-table entry
const Row = extern struct {
    /// Instruction offset within the module's unwind address range
    pc: u32,
    /// Offset used by the CFA calculation
    cfa_offset: i32,
    /// Indicates how to calculate the CFA
    cfa_type: u8,
    /// Indicates how to recover the previous frame pointer (rbp)
    rbp_type: u8,
    /// Offset used by the frame-pointer recovery rule
    rbp_offset: i16,
};

const UnwindRowResult = struct {
    /// whether the lookup succeeded or why it failed
    status: u8,
    /// the unwind rule found in the metadata
    row: Row,
    /// the ID of the module containing the instruction
    module: u32,
    /// the instruction address translated to the module's file address
    file_addr: u64,
};

/// metadata for an executable or library
const Module = extern struct {
    /// base address used to calculate offsets into the module's unwind address range.
    base: u64,
    /// index of this module's first row in the global rows array
    row_start: u32,
    /// number of rows belonging to this module
    row_count: u32,
    /// end of the module's supported relative address range
    end: u32,
    /// currently unused space, possibly reserved for future use
    reserved: u32,
};

const Mapping = extern struct {
    start: u64,
    end: u64,
    bias: u64,
    module: u32,
    reserved: u32,
};

const ProcessEntry = extern struct {
    count: u32,
    dropped: u32,
    mappings: [MAX_MAPPINGS]Mapping,
};

comptime {
    if (@sizeOf(Row) != 12 or @sizeOf(Module) != 24 or @sizeOf(Mapping) != 32 or
        @sizeOf(ProcessEntry) != 8 + MAX_MAPPINGS * 32) @compileError("unwind table layout");
}

/// Result of one unwinding step: caller registers or a stop reason.
const UnwindStep = struct {
    stop_reason: u64,
    caller_pc: u64,
    caller_sp: u64,
    caller_bp: u64,
};

const UnwindResult = struct {
    /// caller recovered, end of trace, unsupported rule, or failure
    status: u8,
    /// the caller's instruction address, recovered from the return address
    pc: u64,
    /// the caller's stack pointer
    sp: u64,
    /// the caller's base pointer
    bp: u64,
};

/// Slot 0 holds the tgid to profile; 0 means "profile nothing"
/// Holds the PID we want to profile
export var target_pid: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

export var oncpu_stack_state: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PERCPU_ARRAY,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(OnCpuStackState),
    .max_entries = 1,
};

export var oncpu_stack_continuations: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(u32),
    .max_entries = 1,
};

export var oncpu_stack_counts: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = @sizeOf(StackCountKey),
    .value_size = @sizeOf(u64),
    .max_entries = 8192,
};

/// Each entry is keyed by a process's TGID and holds its 4104-byte ProcessEntry
export var unwind_procs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = 4,
    .value_size = @sizeOf(ProcessEntry),
    .max_entries = MAX_PROCESSES,
};

/// A shared ring buffer used by all CPUs to submit instruction samples.
export var sample_ring_buffer: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.RINGBUF,
    .key_size = 0,
    .value_size = 0,
    .max_entries = RING_BUFFER_BYTES,
};

/// Each entry contains one 24-byte Module.
export var unwind_modules: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(Module),
    .max_entries = MAX_MODULES,
};
/// Holds all unwind rows in one large array
export var unwind_rows: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = MAX_ROWS * @sizeOf(Row),
    .max_entries = 1,
};

export fn sampleOnCpuStack(ctx: *anyopaque) linksection("perf_event/oncpu_walk") c_int {
    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const state_ptr =
        bpf_map_lookup_elem(&oncpu_stack_state, &key) orelse return 0;
    const state: *OnCpuStackState = @ptrCast(@alignCast(state_ptr));

    if (state.walk_in_progress == 0) {
        const task = bpf_get_current_task_btf() orelse return 0;
        const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
        const regs: *const CpuRegisters = @ptrCast(@alignCast(regs_ptr));
        const sampled_regs: *const CpuRegisters = @ptrCast(@alignCast(ctx));

        state.walk_in_progress = 1;
        state.current_pc = regs.ip;
        state.current_sp = regs.sp;
        state.current_bp = regs.bp;

        state.current_pc_is_initial = 1;
        state.frame_count = 0;
        state.frame_pointer_steps = 0;
        state.stack_hash = 0;

        // Detect whether the sampled user PC follows a syscall instruction.
        var preceding_instruction_bytes: u64 = 0;
        if (regs.ip >= 8) {
            _ = bpf_probe_read_user(
                &preceding_instruction_bytes,
                @sizeOf(@TypeOf(preceding_instruction_bytes)),
                regs.ip - 8,
            );
        }

        const sample_in_user_mode = (sampled_regs.cs & 3) == 3;
        const immediately_after_syscall =
            (preceding_instruction_bytes >> 48) == 0x050f;

        const initial_pc_is_return_address =
            !sample_in_user_mode and immediately_after_syscall;

        state.current_pc_is_initial =
            if (initial_pc_is_return_address) 0 else 1;
        state.initial_pc_is_return_address =
            if (initial_pc_is_return_address) 1 else 0;

        state.record.flags =
            (if (initial_pc_is_return_address) @as(u8, 1) else 0) |
            (if (sample_in_user_mode) @as(u8, 0) else 2);

        if (!sample_in_user_mode) {
            state.walks_from_kernel += 1;
        }
    }

    const stop_reason = unwindStackBatch(state, current_tgid);

    if (stop_reason != 0) {
        finishStackSample(ctx, state, current_tgid, stop_reason);
        return 0;
    }

    _ = bpf_tail_call(ctx, &oncpu_stack_continuations, 0);

    // Reached only if the continuation tail call failed.
    finishStackSample(ctx, state, current_tgid, STOP_TAIL_CALL_FAILED);
    return 0;
}

/// Atomically increments a shared counter.
inline fn incrementCounter(counter: *anyopaque) void {
    _ = @atomicRmw(
        u64,
        @as(*u64, @ptrCast(@alignCast(counter))),
        .Add,
        1,
        .monotonic,
    );
}

/// Finalizes a stack sample, optionally appends kernel frames,
/// and submits a new stack record unless this stack was seen before.
inline fn finishStackSample(ctx: *anyopaque, state: *OnCpuStackState, tgid: u32, stop_reason: u64) void {
    state.walk_in_progress = 0;
    state.completed_walks += 1;

    if (stop_reason < stack_record.STOP_REASON_COUNT) {
        state.stop_reason_counts[stop_reason] += 1;
    }

    var user_frame_count = state.frame_count;
    if (user_frame_count > MAX_STACK_FRAMES) {
        user_frame_count = MAX_STACK_FRAMES;
    }

    state.record.user_frame_count = @truncate(user_frame_count);

    // Append the kernel stack after the user stack when sampled in kernel mode.
    var combined_stack_hash = state.stack_hash;
    var kernel_frame_count: u64 = 0;

    if ((state.record.flags & 2) != 0) {
        const kernel_stack_bytes =
            MAX_KERNEL_STACK_FRAMES * @sizeOf(u64);

        const bytes_written = bpf_get_stack(
            ctx,
            &state.stack_frames[user_frame_count],
            kernel_stack_bytes,
            0,
        );

        if (bytes_written > 0) {
            kernel_frame_count =
                @as(u64, @intCast(bytes_written)) / @sizeOf(u64);

            if (kernel_frame_count > MAX_KERNEL_STACK_FRAMES) {
                kernel_frame_count = MAX_KERNEL_STACK_FRAMES;
            }

            var index: u64 = 0;
            while (index < kernel_frame_count) : (index += 1) {
                combined_stack_hash = updateStackHash(
                    combined_stack_hash ^
                        state.stack_frames[user_frame_count + index],
                );
            }

            // A full kernel buffer may mean the kernel stack was truncated.
            if (kernel_frame_count == MAX_KERNEL_STACK_FRAMES) {
                state.record.flags |= 4;
            }
        }
    }

    state.record.kernel_frame_count = @truncate(kernel_frame_count);
    state.record.stack_hash = updateStackHash(
        combined_stack_hash ^
            ((stop_reason << 1) | state.initial_pc_is_return_address),
    );

    state.record.tgid = tgid;
    state.record.stop_reason = @truncate(stop_reason);

    const count_key = StackCountKey{
        .stack_hash = state.record.stack_hash,
        .tgid = tgid,
        .reserved = 0,
    };

    // If this stack was already recorded, increment its occurrence count.
    if (bpf_map_lookup_elem(&oncpu_stack_counts, &count_key)) |seen_count| {
        incrementCounter(seen_count);
        state.repeated_stacks += 1;
        return;
    }

    const record_size =
        STACK_RECORD_HEADER_BYTES +
        (user_frame_count + kernel_frame_count) * @sizeOf(u64);

    if (bpf_ringbuf_output(
        &sample_ring_buffer,
        &state.record.stack_hash,
        @truncate(record_size),
        0,
    ) != 0) {
        // The stack was not emitted, so a later sample can try again.
        state.records_dropped += 1;
        return;
    }

    state.records_sent += 1;

    // Store the first occurrence count for this stack.
    var initial_count: u64 = 1;
    if (bpf_map_update_elem(
        &oncpu_stack_counts,
        &count_key,
        &initial_count,
        BPF.NOEXIST,
    ) != 0) {
        // Another CPU may have inserted the same stack in the meantime.
        if (bpf_map_lookup_elem(&oncpu_stack_counts, &count_key)) |seen_count| {
            incrementCounter(seen_count);
        } else {
            state.count_map_insert_failures += 1;
        }
    }
}

/// Unwinds up to FRAMES_PER_BATCH frames.
///
/// Returns zero when another batch is needed, or a STOP_* reason when done.
/// Both diagnostic and production walkers use this function.
inline fn unwindStackBatch(state: anytype, tgid: u32) u64 {
    var frame_index: u32 = 0;

    while (frame_index < FRAMES_PER_BATCH) : (frame_index += 1) {
        const count = state.frame_count;
        if (count >= MAX_STACK_FRAMES) return STOP_TRUNCATED;

        const pc = state.current_pc;
        const sp = state.current_sp;
        const bp = state.current_bp;

        // The initial PC is the sampled instruction unless it is a return
        // address. Later PCs are return addresses, so look up PC - 1.
        const lookup_pc =
            if (state.current_pc_is_initial != 0) pc else pc -% 1;

        const found: UnwindRowResult = @call(.always_inline, findUnwindRow, .{ tgid, lookup_pc });

        // If the first address has no mapping, retain it as a single frame.
        if (found.status == ROW_NO_PROCESS or found.status == ROW_NO_MAPPING) {
            if (count != 0) return STOP_INVALID_STACK;

            state.stack_frames[0] = pc;
            state.frame_count = 1;
            state.stack_hash = updateStackHash(state.stack_hash ^ pc);
            return STOP_NO_MODULE_MAPPING;
        }

        state.stack_frames[count] = pc;
        state.frame_count = count + 1;
        state.stack_hash = updateStackHash(state.stack_hash ^ pc);

        var next = UnwindStep{
            .stop_reason = 0,
            .caller_pc = 0,
            .caller_sp = 0,
            .caller_bp = 0,
        };
        var used_frame_pointer = false;

        if (found.status == ROW_FOUND) {
            const unwind: UnwindResult = @call(
                .always_inline,
                unwindFrame,
                .{ found.row, pc, sp, bp },
            );

            if (unwind.status == UNWIND_CALLER) {
                next.caller_pc = unwind.pc;
                next.caller_sp = unwind.sp;
                next.caller_bp = unwind.bp;
            } else if (unwind.status == UNWIND_END) {
                next.stop_reason = STOP_END;
            } else if (unwind.status == UNWIND_READ_FAILED) {
                next.stop_reason = STOP_STACK_READ_FAILED;
            } else {
                next.stop_reason = STOP_UNSUPPORTED_UNWIND;
            }
        } else if (found.status == ROW_NO_RULE and bp == 0) {
            next.stop_reason = STOP_NO_FUNCTION_INFO;
        } else {
            used_frame_pointer = true;
            next = @call(
                .always_inline,
                unwindWithFramePointer,
                .{ sp, bp },
            );
        }

        if (next.stop_reason != 0) return next.stop_reason;
        if (next.caller_pc == 0) return STOP_END;
        if (next.caller_sp <= sp) return STOP_STACK_POINTER_STUCK;

        if (used_frame_pointer) state.frame_pointer_steps += 1;

        state.current_pc = next.caller_pc;
        state.current_sp = next.caller_sp;
        state.current_bp = next.caller_bp;
        state.current_pc_is_initial = 0;
    }

    return 0;
}

/// Mixes a value into a stack hash using the splitmix64 finalizer.
inline fn updateStackHash(value: u64) u64 {
    var mixed = value;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

/// Find the unwind rule that applies to an instruction pointer.
///
/// Resolves runtime IP -> process mapping -> module -> unwind row.
/// The searches are bounded for eBPF execution.
fn findUnwindRow(tgid: u32, ip: u64) UnwindRowResult {
    var result = UnwindRowResult{
        .status = ROW_NO_PROCESS,
        .row = .{ .pc = 0, .cfa_type = 0, .rbp_type = 0, .cfa_offset = 0, .rbp_offset = 0 },
        .module = 0,
        .file_addr = 0,
    };

    const entry_ptr = bpf_map_lookup_elem(&unwind_procs, &tgid) orelse return result;

    const process: *const ProcessEntry = @ptrCast(@alignCast(entry_ptr));

    if (process.count == 0 or process.count > MAX_MAPPINGS) {
        result.status = ROW_NO_MAPPING;
        return result;
    }

    // Upper-bound search: find the first mapping whose start is greater
    // than IP. The previous mapping is the only possible match.
    var lo: u32 = 0;
    var hi: u32 = process.count;
    var steps: u32 = 0;

    while (lo < hi and steps < MAX_MAPPING_STEPS) : (steps += 1) {
        const mid = lo + (hi - lo) / 2;
        if (mid >= MAX_MAPPINGS) break;

        if (process.mappings[mid].start <= ip) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo < hi or lo == 0) {
        result.status = ROW_NO_MAPPING;
        return result;
    }

    const mapping_index = lo - 1;
    if (mapping_index >= MAX_MAPPINGS) {
        result.status = ROW_NO_MAPPING;
        return result;
    }
    const mapping = &process.mappings[mapping_index];

    if (ip < mapping.start or ip >= mapping.end) {
        result.status = ROW_NO_MAPPING;
        return result;
    }

    if (mapping.module == NO_MODULE or mapping.module >= MAX_MODULES) {
        result.status = ROW_NO_MODULE;
        return result;
    }

    // Convert the runtime instruction address into the module's file address.
    if (ip < mapping.bias) {
        result.status = ROW_NO_RULE;
        return result;
    }
    const file_addr = ip - mapping.bias;

    var module_key = mapping.module;
    const module_ptr = bpf_map_lookup_elem(&unwind_modules, &module_key) orelse {
        result.status = ROW_NO_MODULE;
        return result;
    };
    const module: *const Module = @ptrCast(@alignCast(module_ptr));

    if (file_addr < module.base) {
        result.status = ROW_NO_RULE;
        return result;
    }

    const rel = file_addr - module.base;

    if (rel >= module.end or module.row_count == 0) {
        result.status = ROW_NO_RULE;
        return result;
    }

    // Validate the row range before indexing the global row array.
    if (module.row_start >= MAX_ROWS or
        module.row_count > MAX_ROWS - module.row_start)
    {
        result.status = ROW_INVALID_TABLE;
        return result;
    }

    var rows_key: u32 = 0;
    const rows_ptr = bpf_map_lookup_elem(&unwind_rows, &rows_key) orelse {
        result.status = ROW_INVALID_TABLE;
        return result;
    };
    const rows: *const [MAX_ROWS]Row = @ptrCast(@alignCast(rows_ptr));

    // Find the last row whose PC offset is <= the relative instruction address.
    lo = 0;
    hi = module.row_count;
    steps = 0;

    while (lo < hi and steps < MAX_ROW_STEPS) : (steps += 1) {
        const mid = lo + (hi - lo) / 2;
        const row_index = module.row_start + mid;

        if (row_index >= MAX_ROWS) break;

        if (@as(u64, rows[row_index].pc) <= rel) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo < hi or lo == 0) {
        result.status = ROW_NO_RULE;
        return result;
    }

    const row_index = module.row_start + (lo - 1);
    if (row_index >= MAX_ROWS) {
        result.status = ROW_NO_RULE;
        return result;
    }
    const row = &rows[row_index];

    if (@as(u64, row.pc) > rel or row.cfa_type == 0) {
        result.status = ROW_NO_RULE;
        return result;
    }

    result.status = ROW_FOUND;
    result.row = row.*;
    result.module = mapping.module;
    result.file_addr = file_addr;
    return result;
}

/// Recover the caller's PC, SP and BP using the current frame's unwind rule.
///
/// Reads user stack memory through bpf_probe_read_user, which reports failure
/// instead of directly dereferencing an invalid user address.
fn unwindFrame(row: Row, ip: u64, sp: u64, bp: u64) UnwindResult {
    var result = UnwindResult{
        .status = UNWIND_UNSUPPORTED,
        .pc = 0,
        .sp = 0,
        .bp = 0,
    };

    var cfa: u64 = 0;

    switch (row.cfa_type) {
        // CFA = SP + signed offset.
        2 => {
            if (!applySignedOffset(sp, row.cfa_offset, &cfa)) {
                result.status = UNWIND_READ_FAILED;
                return result;
            }
        },

        // CFA = BP + signed offset.
        3 => {
            if (!applySignedOffset(bp, row.cfa_offset, &cfa)) {
                result.status = UNWIND_READ_FAILED;
                return result;
            }
        },

        // PLT stub: CFA depends on the current position within its 16 bytes.
        4 => {
            if (row.cfa_offset < 0 or row.cfa_offset > 15) return result;

            const extra: u64 = if ((ip & 15) >= @as(u64, @intCast(row.cfa_offset)))
                8
            else
                0;

            if (!applySignedOffset(sp, @as(i64, @intCast(8 + extra)), &cfa)) {
                result.status = UNWIND_READ_FAILED;
                return result;
            }
        },

        5 => {
            result.status = UNWIND_END;
            return result;
        },

        0 => {
            result.status = UNWIND_NO_RULE;
            return result;
        },

        else => return result,
    }

    // The return address is stored immediately before the CFA.
    if (cfa < 8) {
        result.status = UNWIND_READ_FAILED;
        return result;
    }

    var return_address: u64 = 0;
    if (bpf_probe_read_user(&return_address, 8, cfa - 8) != 0) {
        result.status = UNWIND_READ_FAILED;
        return result;
    }

    var caller_bp = bp;

    if (row.rbp_type == 1) {
        var saved_bp_address: u64 = 0;
        if (!applySignedOffset(cfa, row.rbp_offset, &saved_bp_address)) {
            result.status = UNWIND_READ_FAILED;
            return result;
        }

        // If the saved BP is still on the current stack, recover it.
        // Otherwise, BP may already have been restored by the function.
        if (saved_bp_address >= sp) {
            var saved_bp: u64 = 0;
            if (bpf_probe_read_user(&saved_bp, 8, saved_bp_address) != 0) {
                result.status = UNWIND_READ_FAILED;
                return result;
            }
            caller_bp = saved_bp;
        }
    } else if (row.rbp_type != 0) {
        return result;
    }

    result.status = UNWIND_CALLER;
    result.pc = return_address;
    result.sp = cfa;
    result.bp = caller_bp;
    return result;
}

/// Apply a signed offset without allowing address overflow or underflow.
fn applySignedOffset(address: u64, offset: i64, result: *u64) bool {
    if (offset >= 0) {
        const amount: u64 = @intCast(offset);

        if (address > (~@as(u64, 0)) - amount) {
            return false;
        }

        result.* = address + amount;
        return true;
    }

    const amount: u64 = @intCast(-offset);

    if (address < amount) {
        return false;
    }

    result.* = address - amount;
    return true;
}

/// Recovers caller registers from a conventional frame-pointer layout.
inline fn unwindWithFramePointer(stack_pointer: u64, frame_pointer: u64) UnwindStep {
    var result = UnwindStep{
        .stop_reason = 0,
        .caller_pc = 0,
        .caller_sp = 0,
        .caller_bp = 0,
    };

    if (frame_pointer == 0) {
        result.stop_reason = STOP_END;
        return result;
    }

    if (frame_pointer < stack_pointer or
        frame_pointer % 8 != 0 or
        frame_pointer > (~@as(u64, 0)) - 16)
    {
        result.stop_reason = STOP_INVALID_FRAME_POINTER;
        return result;
    }

    var saved_frame: [2]u64 = undefined;
    if (bpf_probe_read_user(
        &saved_frame,
        @sizeOf(@TypeOf(saved_frame)),
        frame_pointer,
    ) != 0) {
        result.stop_reason = STOP_STACK_READ_FAILED;
        return result;
    }

    const caller_bp = saved_frame[0];
    const caller_pc = saved_frame[1];

    if (caller_bp != 0 and
        (caller_bp <= frame_pointer or caller_bp % 8 != 0))
    {
        result.stop_reason = STOP_INVALID_FRAME_POINTER;
        return result;
    }

    result.caller_pc = caller_pc;
    result.caller_sp = frame_pointer + 16;
    result.caller_bp = caller_bp;
    return result;
}

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };
