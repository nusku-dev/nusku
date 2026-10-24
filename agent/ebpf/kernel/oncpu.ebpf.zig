const BPF = @import("bpf.zig").BPF;
// Kernel side of the on-CPU profiler: runs on every perf_even sample (99 Hz per CPU)

// -- kernel helpers --
// A helper is called by number (BPF_FUNC_* in linux/bpf.h)
const bpf_map_lookup_elem: *align(1) const fn (*const anyopaque, *const anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(BPF.MAP.LOOKUP_ELEM);
const bpf_get_stackid: *align(1) const fn (*anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.STACKID);
const bpf_get_current_pid_tgid: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(BPF.GET.CURRENT_PID_TGID);
const bpf_map_update_elem: *align(1) const fn (*const anyopaque, *const anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(BPF.MAP.UPDATE_ELEM);
const bpf_get_smp_processor_id: *align(1) const fn () callconv(.c) u32 = @ptrFromInt(BPF.GET.SMP_PROCESSOR_ID);
const bpf_get_current_task_btf: *align(1) const fn () callconv(.c) ?*anyopaque = @ptrFromInt(BPF.GET.CURRENT_TASK_BTF);
const bpf_task_pt_regs: *align(1) const fn (*anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(BPF.GET.TASK_PT_REGS);
const bpf_probe_read_user: *align(1) const fn (*anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.PROBE_READ_USER);
const bpf_tail_call: *align(1) const fn (*anyopaque, *anyopaque, u32) callconv(.c) c_long = @ptrFromInt(BPF.GET.TAIL_CALL);
const bpf_ringbuf_output: *align(1) const fn (*const anyopaque, *const anyopaque, u64, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.RINGBUF_OUTPUT);
const bpf_get_stack: *align(1) const fn (*anyopaque, *anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.STACK);
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

// a structure that stores the values of CPU registers on x86-64 Linux
const CpuRegisters = extern struct { r15: u64, r14: u64, r13: u64, r12: u64, bp: u64, bx: u64, r11: u64, r10: u64, r9: u64, r8: u64, ax: u64, cx: u64, dx: u64, si: u64, di: u64, orig_ax: u64, ip: u64, cs: u64, flags: u64, sp: u64, ss: u64 };

/// Defines the expected memory layout of x86-64 saved registers
const RegisterSlot = extern struct {
    samples: u64,
    user_mode: u64,
    same_ip: u64,
    ip: u64,
    sp: u64,
    bp: u64,
    ctx_ip: u64,
    ctx_cs: u64,
};

/// A BPF array map with one debug slot per CPU, up to 256 CPU
export var regs_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(RegisterSlot),
    .max_entries = MAX_CPUS,
};

/// One slot per CPU, written only by that CPU's samples.
const MAX_CPUS = 256;

comptime {
    if (@offsetOf(CpuRegisters, "bp") != 32 or
        @offsetOf(CpuRegisters, "ip") != 128 or
        @offsetOf(CpuRegisters, "cs") != 136 or
        @offsetOf(CpuRegisters, "sp") != 152) @compileError("CPU Registers layout");
}
/// only reads registers. Not attached by the profiler
/// diagnostic eBPF function that checks and compares CPU register values for a specific process,
/// then saves the results in a BPF map for userspace to inspect
export fn readRegisters(ctx: *anyopaque) linksection("perf_event/regs") c_int {
    var key: u32 = 0;

    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const slot_ptr = bpf_map_lookup_elem(&regs_debug, &cpu) orelse return 0;
    const slot: *RegisterSlot = @ptrCast(@alignCast(slot_ptr));

    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;

    const sampled: *const CpuRegisters = @ptrCast(@alignCast(ctx));

    const task = bpf_get_current_task_btf() orelse return 0;
    const task_regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const task_regs: *const CpuRegisters = @ptrCast(@alignCast(task_regs_ptr));

    slot.samples += 1;

    const is_user_mode = (sampled.cs & 3) == 3;
    if (is_user_mode) {
        slot.user_mode += 1;

        if (sampled.ip == task_regs.ip) {
            slot.same_ip += 1;
        }
    }

    slot.ip = task_regs.ip;
    slot.sp = task_regs.sp;
    slot.bp = task_regs.bp;
    slot.ctx_ip = sampled.ip;
    slot.ctx_cs = sampled.cs;

    return 0;
}

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

/// diagnostic results
const LookupSlot = extern struct {
    /// Number of samples that reached the diagnostic counter
    samples: u64,
    /// No process entry was found
    no_process: u64,
    /// No valid memory mapping contained the instruction address
    no_mapping: u64,
    /// A usable module or row table couldn't be obtained
    no_table: u64,
    /// No suitable unwind row was found
    no_row: u64,
    /// Number of successful row lookups
    found: u64,
    /// Runtime instruction address
    found_ip: u64,
    /// Module index associated with the mapping
    found_module: u64,
    /// Translated file address
    found_file_addr: u64,
    /// The selected row's unwind rules
    row_pc: u64,
    row_cfa_type: u64,
    row_cfa_offset: i64,
    row_rbp_type: u64,
    row_rbp_offset: i64,
    /// Iterations used in the mapping search
    mapping_steps: u64,
    /// Iterations used in the row search
    row_steps: u64,
};

/// used to store debugging statistics for findUnwindRow()
export var lookup_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(LookupSlot),
    .max_entries = MAX_CPUS,
};

/// Each entry is keyed by a process's TGID and holds its 4104-byte ProcessEntry
export var unwind_procs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = 4,
    .value_size = @sizeOf(ProcessEntry),
    .max_entries = MAX_PROCESSES,
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

/// finds the correct unwind-table row for the current instruction address of a target process.
export fn findUnwindTable(ctx: *anyopaque) linksection("perf_event/lookup") c_int {
    _ = ctx;

    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const slot_ptr = bpf_map_lookup_elem(&lookup_debug, &cpu);
    const slot: *LookupSlot = @ptrCast(@alignCast(slot_ptr));
    slot.samples += 1;

    const task = bpf_get_current_task_btf() orelse return 0;
    const task_regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const task_regs: *const CpuRegisters = @ptrCast(@alignCast(task_regs_ptr));

    const entry_ptr = bpf_map_lookup_elem(&unwind_procs, &current_tgid) orelse {
        slot.no_process += 1;
        return 0;
    };
    const process_entry: *const ProcessEntry = @ptrCast(@alignCast(entry_ptr));

    // Reject invalid metadata instead of silently truncating the count.
    if (process_entry.count > MAX_MAPPINGS) {
        slot.no_mapping += 1;
        return 0;
    }

    if (process_entry.count == 0) {
        slot.no_mapping += 1;
        return 0;
    }
    // Upper-bound search: find the first mapping whose start is greater than ip.
    // The preceding mapping is the only possible mapping containing ip.
    var lo: u32 = 0;
    var hi: u32 = process_entry.count;
    var mapping_steps: u32 = 0;
    const ip = task_regs.ip;

    while (lo < hi and mapping_steps < MAX_MAPPING_STEPS) : (mapping_steps += 1) {
        const mid = lo + (hi - lo) / 2;

        if (process_entry.mappings[mid].start <= ip) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    slot.mapping_steps = mapping_steps;

    // If the bounded search did not converge, do not trust its result.
    if (lo != hi or lo == 0 or lo > process_entry.count) {
        slot.no_mapping += 1;
        return 0;
    }

    const mapping_index = lo - 1;
    if (mapping_index >= MAX_MAPPINGS) {
        slot.no_mapping += 1;
        return 0;
    }

    const mapping = &process_entry.mappings[mapping_index];

    // Mapping ranges are [start, end).
    if (mapping.start > ip or ip >= mapping.end) {
        slot.no_mapping += 1;
        return 0;
    }

    if (mapping.module == NO_MODULE or mapping.module >= MAX_MODULES) {
        slot.no_table += 1;
        return 0;
    }

    //  Convert the runtime address into the module's file address
    if (ip < mapping.bias) {
        slot.no_row += 1;
        return 0;
    }

    const file_addr = ip - mapping.bias;
    const module_id = mapping.module;

    const module_ptr = bpf_map_lookup_elem(&unwind_modules, &module_id) orelse {
        slot.no_table += 1;
        return 0;
    };

    const module: *const Module = @ptrCast(@alignCast(module_ptr));

    // Calculate the module-relative instruction address.
    if (file_addr < module.base) {
        slot.no_row += 1;
        return 0;
    }

    const relative_pc = file_addr - module.base;

    if (relative_pc >= module.end or module.row_count == 0) {
        slot.no_row += 1;
        return 0;
    }

    // Validate the complete row range before indexing the global row array.
    const max_rows: u32 = MAX_ROWS;
    if (module.row_start > max_rows or module.row_count > max_rows - module.row_start) {
        slot.no_row += 1;
        return 0;
    }

    // Get the global row array once.
    var rows_key: u32 = 0;
    const rows_ptr = bpf_map_lookup_elem(&unwind_rows, &rows_key) orelse {
        slot.no_table += 1;
        return 0;
    };

    const rows: *const [MAX_ROWS]Row = @ptrCast(@alignCast(rows_ptr));

    // Upper-bound search within this module's sorted rows.
    // Find the first row whose pc is greater than relative_pc.
    lo = 0;
    hi = module.row_count;
    var row_steps: u32 = 0;
    while (lo < hi and row_steps < MAX_ROW_STEPS) : (row_steps += 1) {
        const mid = lo + (hi - lo) / 2;
        const probe_index = module.row_start + mid;

        if (rows[probe_index].pc <= relative_pc) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    slot.row_steps = row_steps;

    // Never use a candidate from an incomplete search.
    if (lo != hi or lo == 0 or lo > module.row_count) {
        slot.no_row += 1;
        return 0;
    }

    const selected_row_index = module.row_start + lo - 1;
    if (selected_row_index >= MAX_ROWS) {
        slot.no_row += 1;
        return 0;
    }

    const row = &rows[selected_row_index];

    // Reject addresses before the selected row or rows without CFA rules.
    if (@as(u64, row.pc) > relative_pc or row.cfa_type == 0) {
        slot.no_row += 1;
        return 0;
    }

    // Record the successful lookup for userspace diagnostics.
    slot.found += 1;
    slot.found_ip = ip;
    slot.found_module = module_id;
    slot.found_file_addr = file_addr;
    slot.row_pc = row.pc;
    slot.row_cfa_type = row.cfa_type;
    slot.row_cfa_offset = row.cfa_offset;
    slot.row_rbp_type = row.rbp_type;
    slot.row_rbp_offset = row.rbp_offset;

    return 0;
}

const TRACE_STACK_WORDS = 64;
const CAPTURE_STACK_SNAPSHOT = false;

// Per-CPU counters and the last successfully recovered frame.
const FrameTraceStats = extern struct {
    /// Count tracing outcomes
    samples: u64,
    lookup_failed: u64,
    unwound: u64,
    ended: u64,
    failed: u64,
    /// Save the inputs and module information for the last successful unwind
    ip: u64,
    sp: u64,
    bp: u64,
    module: u64,
    file_addr: u64,
    /// Save the recovered caller registers
    caller_pc: u64,
    caller_sp: u64,
    caller_bp: u64,
    /// Indicate whether the optional stack-memory snapshot succeeded and store its contents
    snapshot_ok: u64,
    // Optional snapshot of the first 512 bytes of the user stack.
    stack: [TRACE_STACK_WORDS]u64,
};

/// tracks how many frames were traced successfully or failed,
/// and saves the latest successful frame's registers and caller information
/// so userspace can inspect them
export var frame_trace_stats: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(FrameTraceStats),
    .max_entries = MAX_CPUS,
};

/// Trace one frame for the target process.
///
/// Reads the current registers, finds their unwind rule, attempts to recover
/// the caller, and records the outcome in the per-CPU diagnostics map.
export fn traceFrame(ctx: *anyopaque) linksection("perf_event/step") c_int {
    _ = ctx;

    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const stats_ptr = bpf_map_lookup_elem(&frame_trace_stats, &cpu) orelse return 0;
    const stats: *FrameTraceStats = @ptrCast(@alignCast(stats_ptr));
    stats.samples += 1;

    const task = bpf_get_current_task_btf() orelse {
        stats.failed += 1;
        return 0;
    };

    const regs_ptr = bpf_task_pt_regs(task) orelse {
        stats.failed += 1;
        return 0;
    };

    const regs: *const CpuRegisters = @ptrCast(@alignCast(regs_ptr));

    const ip = regs.ip;
    const sp = regs.sp;
    const bp = regs.bp;

    //  Find the unwind rule for the current instruction.
    const found: UnwindRowResult = @call(.always_inline, findUnwindRow, .{ current_tgid, ip });
    if (found.status != ROW_FOUND) {
        stats.lookup_failed += 1;
        return 0;
    }

    // Use the rule to recover the caller's registers.
    const caller: UnwindResult = @call(.always_inline, unwindFrame, .{ found.row, ip, sp, bp });
    if (caller.status == UNWIND_END) {
        stats.ended += 1;
        return 0;
    }
    if (caller.status != UNWIND_CALLER) {
        stats.failed += 1;
        return 0;
    }

    //  Record the successfully recovered caller.
    stats.unwound += 1;
    stats.ip = ip;
    stats.sp = sp;
    stats.bp = bp;
    stats.module = found.module;
    stats.file_addr = found.file_addr;
    stats.caller_pc = caller.pc;
    stats.caller_sp = caller.sp;
    stats.caller_bp = caller.bp;

    stats.snapshot_ok = 0;
    if (CAPTURE_STACK_SNAPSHOT) {
        stats.snapshot_ok = if (bpf_probe_read_user(
            &stats.stack,
            @sizeOf(@TypeOf(stats.stack)),
            sp,
        ) == 0) 1 else 0;
    }

    return 0;
}

// Lookup results.
const ROW_FOUND: u8 = 0;
const ROW_NO_PROCESS: u8 = 1;
const ROW_NO_MAPPING: u8 = 2;
const ROW_NO_MODULE: u8 = 3;
const ROW_NO_RULE: u8 = 4;
const ROW_INVALID_TABLE: u8 = 5;

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

    const mapping = &process.mappings[lo - 1];
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

// Results from recovering the caller's registers.
const UNWIND_CALLER: u8 = 0;
const UNWIND_END: u8 = 1;
const UNWIND_NO_RULE: u8 = 2;
const UNWIND_UNSUPPORTED: u8 = 3;
const UNWIND_READ_FAILED: u8 = 4;

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

/// Per-CPU statistics for measuring tail-call chain depth.
const TailCallStats = extern struct {
    /// Nonzero while a chain is being measured.
    chain_active: u64,
    /// Number of invocations counted in the current chain.
    current_depth: u64,
    /// Number of chains terminated by a failed tail call.
    completed_chains: u64,
    /// Smallest recorded chain depth.
    minimum_depth: u64,
    /// Largest recorded chain depth.
    maximum_depth: u64,
};

/// One statistics slot per CPU.
export var tail_call_stats: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(TailCallStats),
    .max_entries = MAX_CPUS,
};

/// can be reached through tail calls.
/// Userspace must populate index 0 with the target program.
export var tail_call_programs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

/// Measure how many times the tail-call target runs before a tail call fails.
///
/// Each successful tail call transfers execution to the target program.
/// When a tail call fails, record the accumulated depth and finish the chain.
export fn measureTailCallDepth(ctx: *anyopaque) linksection("perf_event/chain") c_int {
    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const stats_ptr = bpf_map_lookup_elem(&tail_call_stats, &cpu) orelse return 0;
    const stats: *TailCallStats = @ptrCast(@alignCast(stats_ptr));

    // Start a new chain if this is its first invocation.
    if (stats.chain_active == 0) {
        stats.chain_active = 1;
        stats.current_depth = 0;
    }

    stats.current_depth += 1;

    // Transfer execution to the program at index 0.
    // On success, this invocation does not return here.
    _ = bpf_tail_call(ctx, &tail_call_programs, 0);

    //  Reached only when the tail call fails.
    const depth = stats.current_depth;

    stats.chain_active = 0;
    stats.completed_chains += 1;

    if (stats.minimum_depth == 0 or depth < stats.minimum_depth) {
        stats.minimum_depth = depth;
    }

    if (depth > stats.maximum_depth) {
        stats.maximum_depth = depth;
    }

    return 0;
}

const FRAMES_PER_BATCH = 4;
const MAX_STACK_FRAMES = 128;
const STACK_SNAPSHOT_CHUNK_BYTES = 512;
const STACK_SNAPSHOT_CHUNKS = 32;

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

const StackWalkState = extern struct {
    walk_in_progress: u64,
    completed_walks: u64,
    walks_from_kernel: u64,

    // Current frame registers.
    current_pc: u64,
    current_sp: u64,
    current_bp: u64,
    current_pc_is_initial: u64,
    frame_pointer_steps: u64,

    // Initial state, retained for reproducing the last walk.
    initial_pc: u64,
    initial_sp: u64,
    initial_bp: u64,
    sampled_in_kernel: u64,
    initial_pc_is_return_address: u64,
    instruction_bytes_before_pc: u64,
    captured_stack_bytes: u64,

    // Walk result.
    frame_count: u64,
    stop_reason: u64,
    stack_hash: u64,
    stop_reason_counts: [16]u64,
    stack_frames: [MAX_STACK_FRAMES]u64,
    user_stack_snapshot: [STACK_SNAPSHOT_CHUNK_BYTES * STACK_SNAPSHOT_CHUNKS / 8]u64,
};

export var stack_walk_states: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(StackWalkState),
    .max_entries = MAX_CPUS,
};

export var stack_walk_programs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

export fn startOrContinueStackWalk(ctx: *anyopaque) linksection("perf_event/walk") c_int {
    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const state_ptr = bpf_map_lookup_elem(&stack_walk_states, &cpu) orelse return 0;
    const state: *StackWalkState = @ptrCast(@alignCast(state_ptr));

    if (state.walk_in_progress == 0) {
        const task = bpf_get_current_task_btf() orelse return 0;
        const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
        const regs: *const CpuRegisters = @ptrCast(@alignCast(regs_ptr));
        const sampled: *const CpuRegisters = @ptrCast(@alignCast(ctx));

        state.walk_in_progress = 1;
        state.current_pc = regs.ip;
        state.current_sp = regs.sp;
        state.current_bp = regs.bp;

        state.initial_pc = regs.ip;
        state.initial_sp = regs.sp;
        state.initial_bp = regs.bp;

        state.frame_count = 0;
        state.frame_pointer_steps = 0;
        state.stack_hash = 0;

        captureUserStack(state, regs.sp);

        state.instruction_bytes_before_pc = 0;
        if (regs.ip >= 8) {
            _ = bpf_probe_read_user(
                &state.instruction_bytes_before_pc,
                @sizeOf(@TypeOf(state.instruction_bytes_before_pc)),
                regs.ip - 8,
            );
        }

        const in_user_mode = (sampled.cs & 3) == 3;
        const after_syscall =
            (state.instruction_bytes_before_pc >> 48) == 0x050f;
        const initial_pc_is_return_address = !in_user_mode and after_syscall;

        state.current_pc_is_initial =
            if (initial_pc_is_return_address) 0 else 1;
        state.initial_pc_is_return_address =
            if (initial_pc_is_return_address) 1 else 0;
        state.sampled_in_kernel = if (in_user_mode) 0 else 1;

        if (!in_user_mode) state.walks_from_kernel += 1;
    }

    const reason = unwindStackBatch(state, current_tgid);
    if (reason != 0) {
        completeStackWalk(state, reason);
        return 0;
    }

    _ = bpf_tail_call(ctx, &stack_walk_programs, 0);

    // The continuation was unavailable or the tail call could not proceed.
    completeStackWalk(state, STOP_TAIL_CALL_FAILED);

    return 0;
}

/// Result of one unwinding step: caller registers or a stop reason.
const UnwindStep = struct {
    stop_reason: u64,
    caller_pc: u64,
    caller_sp: u64,
    caller_bp: u64,
};

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

// Copies readable user-stack memory into the diagnostic snapshot.
inline fn captureUserStack(state: *StackWalkState, stack_pointer: u64) void {
    state.captured_stack_bytes = 0;
    inline for (0..STACK_SNAPSHOT_CHUNKS) |chunk_idx| {
        const offset: u64 = chunk_idx * STACK_SNAPSHOT_CHUNK_BYTES;
        const words_per_chunk = STACK_SNAPSHOT_CHUNK_BYTES / @sizeOf(u64);

        if (stack_pointer > (~@as(u64, 0)) - offset) return;

        const address = stack_pointer + offset;
        if (bpf_probe_read_user(
            &state.user_stack_snapshot[chunk_idx * words_per_chunk],
            STACK_SNAPSHOT_CHUNK_BYTES,
            address,
        ) != 0) return;

        state.captured_stack_bytes = (chunk_idx + 1) * STACK_SNAPSHOT_CHUNK_BYTES;
    }
}

/// Mixes a value into a stack hash using the splitmix64 finalizer.
inline fn updateStackHash(value: u64) u64 {
    var mixed = value;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

/// Records the final result and marks the walk as complete.
inline fn completeStackWalk(state: *StackWalkState, reason: u64) void {
    state.walk_in_progress = 0;
    state.completed_walks += 1;
    state.stop_reason = reason;
    state.stack_hash = updateStackHash(
        state.stack_hash ^
            ((reason << 1) | state.initial_pc_is_return_address),
    );

    if (reason < 16) state.stop_reason_counts[reason] += 1;
}

const RING_BUFFER_BYTES = 256 * 1024;

/// A shared ring buffer used by all CPUs to submit instruction samples.
export var sample_ring_buffer: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.RINGBUF,
    .key_size = 0,
    .value_size = 0,
    .max_entries = RING_BUFFER_BYTES,
};

/// One instruction sample sent to userspace.
const InstructionSample = extern struct {
    sequence: u64,
    instruction_pointer: u64,
    tgid: u32,
    cpu_id: u32,
};

/// Counters maintained separately for each CPU.
const RingBufferCpuStats = extern struct {
    /// Sequence number to assign to the next successful record.
    next_sequence: u64,
    /// Number of records successfully submitted.
    records_sent: u64,
    /// Number of records that could not be submitted because the ring buffer was full.
    records_dropped: u64,
};

/// Says what the map stores
export var ring_buffer_cpu_stats: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = @sizeOf(u32),
    .value_size = @sizeOf(RingBufferCpuStats),
    .max_entries = MAX_CPUS,
};

export fn recordInstructionSample(ctx: *anyopaque) linksection("perf_event/ring") c_int {
    _ = ctx;

    var key: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &key) orelse return 0;
    const target_tgid: *const u32 = @ptrCast(@alignCast(target_ptr));
    if (target_tgid.* == 0) return 0;

    const current_tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (current_tgid != target_tgid.*) return 0;

    const cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;

    const stats_ptr = bpf_map_lookup_elem(&ring_buffer_cpu_stats, &cpu) orelse return 0;
    const stats: *RingBufferCpuStats = @ptrCast(@alignCast(stats_ptr));

    const task = bpf_get_current_task_btf() orelse return 0;
    const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const regs: *const CpuRegisters = @ptrCast(@alignCast(regs_ptr));

    const sample = InstructionSample{
        .sequence = stats.next_sequence,
        .instruction_pointer = regs.ip,
        .tgid = current_tgid,
        .cpu_id = cpu,
    };

    if (bpf_ringbuf_output(
        &sample_ring_buffer,
        &sample,
        @sizeOf(InstructionSample),
        0,
    ) != 0) {
        stats.records_dropped += 1;
        return 0;
    }

    // Advance the sequence only after a successful submission.
    stats.next_sequence += 1;
    stats.records_sent += 1;

    return 0;
}

const STACK_RECORD_HEADER_BYTES = 16;

/// Maximum number of kernel frames appended to a user stack.
const MAX_KERNEL_STACK_FRAMES = 32;

/// Per-CPU state for a production stack sample.
///
/// The record fields must remain contiguous:
/// stack_hash, process ID, frame counts, stop reason, flags, then frames.
/// The ring buffer receives this record starting at `stack_hash`.
const OnCpuStackState = extern struct {
    // State shared with unwindStackBatch().
    walk_in_progress: u64,
    current_pc: u64,
    current_sp: u64,
    current_bp: u64,
    current_pc_is_initial: u64,
    frame_pointer_steps: u64,
    initial_pc_is_return_address: u64,
    stack_hash: u64,
    frame_count: u64,

    // Counters accumulated while the BPF program is loaded.
    completed_walks: u64,
    walks_from_kernel: u64,
    records_sent: u64,
    records_dropped: u64,
    repeated_stacks: u64,
    count_map_insert_failures: u64,
    stop_reason_counts: [16]u64,

    // Record header, followed immediately by the frame addresses.
    record_stack_hash: u64,
    record_tgid: u32,
    record_user_frame_count: u8,
    record_kernel_frame_count: u8,
    record_stop_reason: u8,

    // Bit 0: initial PC is a return address.
    // Bit 1: sample was taken in kernel mode.
    // Bit 2: kernel frame buffer may be truncated.
    record_flags: u8,

    stack_frames: [MAX_STACK_FRAMES + MAX_KERNEL_STACK_FRAMES]u64,
};

comptime {
    if (@offsetOf(OnCpuStackState, "stack_frames") !=
        @offsetOf(OnCpuStackState, "record_stack_hash") +
            STACK_RECORD_HEADER_BYTES)
    {
        @compileError("Stack record header and frame addresses must be contiguous");
    }
}

/// Identifies one unique stack within a process.
const StackCountKey = extern struct {
    stack_hash: u64,
    tgid: u32,
    reserved: u32,
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

        state.record_flags =
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
inline fn finishStackSample(
    ctx: *anyopaque,
    state: *OnCpuStackState,
    tgid: u32,
    stop_reason: u64,
) void {
    state.walk_in_progress = 0;
    state.completed_walks += 1;

    if (stop_reason < 16) {
        state.stop_reason_counts[stop_reason] += 1;
    }

    var user_frame_count = state.frame_count;
    if (user_frame_count > MAX_STACK_FRAMES) {
        user_frame_count = MAX_STACK_FRAMES;
    }

    state.record_user_frame_count = @truncate(user_frame_count);

    // Append the kernel stack after the user stack when sampled in kernel mode.
    var combined_stack_hash = state.stack_hash;
    var kernel_frame_count: u64 = 0;

    if ((state.record_flags & 2) != 0) {
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
                state.record_flags |= 4;
            }
        }
    }

    state.record_kernel_frame_count = @truncate(kernel_frame_count);
    state.record_stack_hash = updateStackHash(
        combined_stack_hash ^
            ((stop_reason << 1) | state.initial_pc_is_return_address),
    );

    state.record_tgid = tgid;
    state.record_stop_reason = @truncate(stop_reason);

    const count_key = StackCountKey{
        .stack_hash = state.record_stack_hash,
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
        &state.record_stack_hash,
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

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };
