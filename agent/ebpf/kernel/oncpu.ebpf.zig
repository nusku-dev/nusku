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

/// One slot per CPU, written only by that CPU's samples. A debug map for the register probe.
const MAX_CPUS = 256;

const RegSlot = extern struct {
    samples: u64,
    /// Samples taken while the CPU was running user code.
    user_mode: u64,
    /// Of those, the ones where the task's user registers agree with the sampled ones.
    same_ip: u64,
    /// The last sample: user registers of the task, then what the sample itself saw.
    ip: u64,
    sp: u64,
    bp: u64,
    ctx_ip: u64,
    ctx_cs: u64,
};

export var regs_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(RegSlot),
    .max_entries = MAX_CPUS,
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

/// x86-64 `struct pt_regs`. The layout is fixed by the ABI, so no kernel version changes it.
const PtRegs = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    bp: u64,
    bx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    ax: u64,
    cx: u64,
    dx: u64,
    si: u64,
    di: u64,
    orig_ax: u64,
    ip: u64,
    cs: u64,
    flags: u64,
    sp: u64,
    ss: u64,
};

comptime {
    if (@offsetOf(PtRegs, "bp") != 32 or @offsetOf(PtRegs, "ip") != 128 or
        @offsetOf(PtRegs, "cs") != 136 or @offsetOf(PtRegs, "sp") != 152) @compileError("pt_regs layout");
}

/// Step 1a of the BPF unwinder: only reads registers. Not attached by the profiler.
export fn regsProbe(ctx: *anyopaque) linksection("perf_event/regs") c_int {
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&regs_debug, &cpu) orelse return 0;
    const slot: *RegSlot = @ptrCast(@alignCast(slot_ptr));

    // The context of a perf_event program starts with the registers of the interrupted code.
    const sampled: *const PtRegs = @ptrCast(@alignCast(ctx));
    const task = bpf_get_current_task_btf() orelse return 0;
    const user_ptr = bpf_task_pt_regs(task) orelse return 0;
    const user: *const PtRegs = @ptrCast(@alignCast(user_ptr));

    slot.samples += 1;
    if ((sampled.cs & 3) == 3) {
        slot.user_mode += 1;
        if (sampled.ip == user.ip) slot.same_ip += 1;
    }
    slot.ip = user.ip;
    slot.sp = user.sp;
    slot.bp = user.bp;
    slot.ctx_ip = sampled.ip;
    slot.ctx_cs = sampled.cs;
    return 0;
}

// ---- Step 1b: find the unwind table row of the interrupted instruction ----
// These layouts must match unwind/compact.zig, tableset.zig and procmap.zig. The loader checks
// the sizes of keys and values when it wraps the maps.

const MAX_MAPPINGS = 128;
const NO_MODULE: u32 = 0xffff_ffff;
const MAX_MAPPING_STEPS = 8;
const MAX_ROW_STEPS = 19;
const MAX_ROWS = 262144;
const MAX_MODULES = 256;
const MAX_PROCESSES = 1024;

const Row = extern struct { pc: u32, cfa_offset: i32, cfa_type: u8, rbp_type: u8, rbp_offset: i16 };
const Module = extern struct { base: u64, row_start: u32, row_count: u32, end: u32, reserved: u32 };
const Mapping = extern struct { start: u64, end: u64, bias: u64, module: u32, reserved: u32 };
const ProcessEntry = extern struct { count: u32, dropped: u32, mappings: [MAX_MAPPINGS]Mapping };

comptime {
    if (@sizeOf(Row) != 12 or @sizeOf(Module) != 24 or @sizeOf(Mapping) != 32 or
        @sizeOf(ProcessEntry) != 8 + MAX_MAPPINGS * 32) @compileError("unwind table layout");
}

/// One entry holding every row: the program takes the pointer once and indexes it, which the
/// verifier checks far more cheaply than a map lookup in every step of a binary search.
export var unwind_rows: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = MAX_ROWS * @sizeOf(Row),
    .max_entries = 1,
};

export var unwind_modules: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(Module),
    .max_entries = MAX_MODULES,
};

export var unwind_procs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = 4,
    .value_size = @sizeOf(ProcessEntry),
    .max_entries = MAX_PROCESSES,
};

/// Per CPU, written only by that CPU's samples. `found_*` and `row_*` all come from the same sample.
const LookupSlot = extern struct {
    samples: u64,
    no_process: u64,
    no_mapping: u64,
    no_table: u64,
    no_row: u64,
    found: u64,
    found_ip: u64,
    found_module: u64,
    found_file_addr: u64,
    row_pc: u64,
    row_cfa_type: u64,
    row_cfa_offset: i64,
    row_rbp_type: u64,
    row_rbp_offset: i64,
    mapping_steps: u64,
    row_steps: u64,
};

export var lookup_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(LookupSlot),
    .max_entries = MAX_CPUS,
};

export fn lookupProbe(ctx: *anyopaque) linksection("perf_event/lookup") c_int {
    _ = ctx;
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    var tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&lookup_debug, &cpu) orelse return 0;
    const slot: *LookupSlot = @ptrCast(@alignCast(slot_ptr));
    slot.samples += 1;

    // The user registers of the task. For a sample inside the kernel this `ip` is the address
    // after the syscall instruction, a return address; step 1d treats it as one.
    const task = bpf_get_current_task_btf() orelse return 0;
    const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const regs: *const PtRegs = @ptrCast(@alignCast(regs_ptr));
    const ip = regs.ip;

    const entry_ptr = bpf_map_lookup_elem(&unwind_procs, &tgid) orelse {
        slot.no_process += 1;
        return 0;
    };
    const entry: *const ProcessEntry = @ptrCast(@alignCast(entry_ptr));

    // Binary search without a branch that depends on the data, so the verifier sees one path
    // per step. `base` ends as the index of the last mapping that starts at or below ip,
    // provided the first one does; that is checked after the loop.
    var n: u32 = entry.count;
    if (n > MAX_MAPPINGS) n = MAX_MAPPINGS;
    if (n == 0) {
        slot.no_mapping += 1;
        return 0;
    }
    var base: u32 = 0;
    var steps: u32 = 0;
    while (n > 1 and steps < MAX_MAPPING_STEPS) : (steps += 1) {
        const half = n / 2;
        const index = base + half;
        if (index >= MAX_MAPPINGS) break;
        // 1 when the mapping at `index` starts at or below ip. Addresses are below 2^63.
        const at_or_below: u32 = @truncate((entry.mappings[index].start -% (ip +% 1)) >> 63);
        base += half * at_or_below;
        n -= half;
    }
    slot.mapping_steps = steps;
    if (base >= MAX_MAPPINGS) {
        slot.no_mapping += 1;
        return 0;
    }
    const mapping = &entry.mappings[base];
    if (mapping.start > ip or ip >= mapping.end) {
        slot.no_mapping += 1;
        return 0;
    }
    if (mapping.module == NO_MODULE) {
        slot.no_table += 1;
        return 0;
    }

    const file_addr = ip -% mapping.bias;
    var module_id: u32 = mapping.module;
    const module_ptr = bpf_map_lookup_elem(&unwind_modules, &module_id) orelse {
        slot.no_table += 1;
        return 0;
    };
    const module: *const Module = @ptrCast(@alignCast(module_ptr));
    if (file_addr < module.base) {
        slot.no_row += 1;
        return 0;
    }
    const rel = file_addr - module.base;
    if (rel >= module.end or module.row_count == 0) {
        slot.no_row += 1;
        return 0;
    }

    var rows_key: u32 = 0;
    const rows_ptr = bpf_map_lookup_elem(&unwind_rows, &rows_key) orelse {
        slot.no_table += 1;
        return 0;
    };
    const rows: *const [MAX_ROWS]Row = @ptrCast(@alignCast(rows_ptr));

    // The same search over the rows. The first row of a module has pc 0, so `base2` ends as
    // the index of the last row that starts at or below rel.
    var n2: u32 = module.row_count;
    var base2: u32 = 0;
    var steps2: u32 = 0;
    while (n2 > 1 and steps2 < MAX_ROW_STEPS) : (steps2 += 1) {
        const half = n2 / 2;
        const probe_index = module.row_start +% base2 +% half;
        if (probe_index >= MAX_ROWS) break;
        const at_or_below: u32 = @truncate((@as(u64, rows[probe_index].pc) -% (rel + 1)) >> 63);
        base2 += half * at_or_below;
        n2 -= half;
    }
    slot.row_steps = steps2;
    const last = module.row_start +% base2;
    if (last >= MAX_ROWS) {
        slot.no_row += 1;
        return 0;
    }
    const row = &rows[last];
    if (@as(u64, row.pc) > rel or row.cfa_type == 0) { // before the table, or a gap between functions
        slot.no_row += 1;
        return 0;
    }

    slot.found += 1;
    slot.found_ip = ip;
    slot.found_module = mapping.module;
    slot.found_file_addr = file_addr;
    slot.row_pc = row.pc;
    slot.row_cfa_type = row.cfa_type;
    slot.row_cfa_offset = row.cfa_offset;
    slot.row_rbp_type = row.rbp_type;
    slot.row_rbp_offset = row.rbp_offset;
    return 0;
}

// ---- Step 1c: one unwind step ----

const bpf_probe_read_user: *align(1) const fn (*anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.PROBE_READ_USER);

const Found = struct { why: u8, row: Row, module: u32, file_addr: u64 };
// why: 0 found, 1 no process entry, 2 no mapping, 3 mapping without table, 4 no row

/// The same search as `lookupProbe`, to be inlined where it is used.
fn findRow(tgid_value: u32, ip: u64) Found {
    var tgid = tgid_value;
    var out = Found{
        .why = 0,
        .row = .{ .pc = 0, .cfa_offset = 0, .cfa_type = 0, .rbp_type = 0, .rbp_offset = 0 },
        .module = 0,
        .file_addr = 0,
    };
    const entry_ptr = bpf_map_lookup_elem(&unwind_procs, &tgid) orelse {
        out.why = 1;
        return out;
    };
    const entry: *const ProcessEntry = @ptrCast(@alignCast(entry_ptr));

    var n: u32 = entry.count;
    if (n > MAX_MAPPINGS) n = MAX_MAPPINGS;
    if (n == 0) {
        out.why = 2;
        return out;
    }
    var base: u32 = 0;
    var steps: u32 = 0;
    while (n > 1 and steps < MAX_MAPPING_STEPS) : (steps += 1) {
        const half = n / 2;
        const index = base + half;
        if (index >= MAX_MAPPINGS) break;
        const at_or_below: u32 = @truncate((entry.mappings[index].start -% (ip +% 1)) >> 63);
        base += half * at_or_below;
        n -= half;
    }
    if (base >= MAX_MAPPINGS) {
        out.why = 2;
        return out;
    }
    const mapping = &entry.mappings[base];
    if (mapping.start > ip or ip >= mapping.end) {
        out.why = 2;
        return out;
    }
    if (mapping.module == NO_MODULE) {
        out.why = 3;
        return out;
    }

    const file_addr = ip -% mapping.bias;
    var module_id: u32 = mapping.module;
    const module_ptr = bpf_map_lookup_elem(&unwind_modules, &module_id) orelse {
        out.why = 3;
        return out;
    };
    const module: *const Module = @ptrCast(@alignCast(module_ptr));
    if (file_addr < module.base) {
        out.why = 4;
        return out;
    }
    const rel = file_addr - module.base;
    if (rel >= module.end or module.row_count == 0) {
        out.why = 4;
        return out;
    }
    var rows_key: u32 = 0;
    const rows_ptr = bpf_map_lookup_elem(&unwind_rows, &rows_key) orelse {
        out.why = 3;
        return out;
    };
    const rows: *const [MAX_ROWS]Row = @ptrCast(@alignCast(rows_ptr));

    var n2: u32 = module.row_count;
    var base2: u32 = 0;
    var steps2: u32 = 0;
    while (n2 > 1 and steps2 < MAX_ROW_STEPS) : (steps2 += 1) {
        const half = n2 / 2;
        const probe_index = module.row_start +% base2 +% half;
        if (probe_index >= MAX_ROWS) break;
        const at_or_below: u32 = @truncate((@as(u64, rows[probe_index].pc) -% (rel + 1)) >> 63);
        base2 += half * at_or_below;
        n2 -= half;
    }
    const last = module.row_start +% base2;
    if (last >= MAX_ROWS) {
        out.why = 4;
        return out;
    }
    const row = &rows[last];
    if (@as(u64, row.pc) > rel or row.cfa_type == 0) {
        out.why = 4;
        return out;
    }
    out.row = row.*;
    out.module = mapping.module;
    out.file_addr = file_addr;
    return out;
}

const STEP_CALLER = 0;
const STEP_END = 1;
const STEP_NO_FUNCTION = 2;
const STEP_UNSUPPORTED = 3;
const STEP_OUTSIDE = 4;

const Step = struct { kind: u8, pc: u64, sp: u64, bp: u64 };

/// What `compact.unwind` does with a row: the registers of the caller. Reads the stack of the
/// process with `bpf_probe_read_user`, which fails instead of faulting.
fn stepOnce(row: Row, ip: u64, sp: u64, bp: u64) Step {
    var out = Step{ .kind = STEP_UNSUPPORTED, .pc = 0, .sp = 0, .bp = 0 };
    var cfa: u64 = 0;
    switch (row.cfa_type) {
        2 => cfa = sp +% @as(u64, @bitCast(@as(i64, row.cfa_offset))),
        3 => cfa = bp +% @as(u64, @bitCast(@as(i64, row.cfa_offset))),
        4 => { // a PLT stub: 8 more once the pc is in the last part of its 16 bytes
            if (row.cfa_offset < 0) return out;
            const threshold: u64 = @intCast(row.cfa_offset);
            cfa = sp +% 8 +% (if ((ip & 15) >= threshold) @as(u64, 8) else 0);
        },
        5 => {
            out.kind = STEP_END;
            return out;
        },
        0 => {
            out.kind = STEP_NO_FUNCTION;
            return out;
        },
        else => return out,
    }

    var ra: u64 = 0;
    if (bpf_probe_read_user(&ra, 8, cfa -% 8) != 0) {
        out.kind = STEP_OUTSIDE;
        return out;
    }
    var caller_bp = bp;
    if (row.rbp_type == 1) {
        const saved_at = cfa +% @as(u64, @bitCast(@as(i64, row.rbp_offset)));
        // Below the stack pointer means already popped: rbp holds the caller's value again.
        if (saved_at >= sp) {
            var saved: u64 = 0;
            if (bpf_probe_read_user(&saved, 8, saved_at) != 0) {
                out.kind = STEP_OUTSIDE;
                return out;
            }
            caller_bp = saved;
        }
    } else if (row.rbp_type != 0) {
        return out;
    }
    out.kind = STEP_CALLER;
    out.pc = ra;
    out.sp = cfa;
    out.bp = caller_bp;
    return out;
}

const STEP_WORDS = 64;

const StepSlot = extern struct {
    samples: u64,
    no_row: u64,
    ok: u64,
    ended: u64,
    failed: u64,
    // The last sample that gave a caller: its inputs, then the caller the program computed.
    ip: u64,
    sp: u64,
    bp: u64,
    module: u64,
    file_addr: u64,
    caller_pc: u64,
    caller_sp: u64,
    caller_bp: u64,
    snapshot_ok: u64,
    /// The first 512 bytes of the user stack at `sp`, copied at the same moment.
    stack: [STEP_WORDS]u64,
};

export var step_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(StepSlot),
    .max_entries = MAX_CPUS,
};

export fn stepProbe(ctx: *anyopaque) linksection("perf_event/step") c_int {
    _ = ctx;
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&step_debug, &cpu) orelse return 0;
    const slot: *StepSlot = @ptrCast(@alignCast(slot_ptr));
    slot.samples += 1;

    const task = bpf_get_current_task_btf() orelse return 0;
    const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const regs: *const PtRegs = @ptrCast(@alignCast(regs_ptr));
    const ip = regs.ip;
    const sp = regs.sp;
    const bp = regs.bp;

    const found = @call(.always_inline, findRow, .{ tgid, ip });
    if (found.why != 0) {
        slot.no_row += 1;
        return 0;
    }
    const next = @call(.always_inline, stepOnce, .{ found.row, ip, sp, bp });
    if (next.kind == STEP_END) {
        slot.ended += 1;
        return 0;
    }
    if (next.kind != STEP_CALLER) {
        slot.failed += 1;
        return 0;
    }

    slot.ok += 1;
    slot.ip = ip;
    slot.sp = sp;
    slot.bp = bp;
    slot.module = found.module;
    slot.file_addr = found.file_addr;
    slot.caller_pc = next.pc;
    slot.caller_sp = next.sp;
    slot.caller_bp = next.bp;
    slot.snapshot_ok = if (bpf_probe_read_user(&slot.stack, @sizeOf(@TypeOf(slot.stack)), sp) == 0) 1 else 0;
    return 0;
}

// ---- Step 1d-a: a program that tail calls itself ----

const bpf_tail_call: *align(1) const fn (*anyopaque, *anyopaque, u32) callconv(.c) c_long = @ptrFromInt(BPF.GET.TAIL_CALL);

export var chain_progs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

const ChainSlot = extern struct {
    /// 1 while a chain is running on this CPU.
    active: u64,
    /// Invocations so far in the running chain.
    depth: u64,
    chains: u64,
    min_depth: u64,
    max_depth: u64,
};

export var chain_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(ChainSlot),
    .max_entries = MAX_CPUS,
};

export fn chainProbe(ctx: *anyopaque) linksection("perf_event/chain") c_int {
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&chain_debug, &cpu) orelse return 0;
    const slot: *ChainSlot = @ptrCast(@alignCast(slot_ptr));

    if (slot.active == 0) {
        slot.active = 1;
        slot.depth = 0;
    }
    slot.depth += 1;

    _ = bpf_tail_call(ctx, &chain_progs, 0);

    // Only reached when the kernel refused the jump: the chain is at its limit.
    const depth = slot.depth;
    slot.active = 0;
    slot.chains += 1;
    if (slot.min_depth == 0 or depth < slot.min_depth) slot.min_depth = depth;
    if (depth > slot.max_depth) slot.max_depth = depth;
    return 0;
}

// ---- Steps 1d-b to 1d-h: the walk ----

const FRAMES_PER_CALL = 4;
const MAX_FRAMES = 128;
const SNAPSHOT_CHUNK = 512;
const SNAPSHOT_CHUNKS = 32;

// Why a walk ended. The numbers are those of `Stop` in unwind/compactwalk.zig.
const STOP_END = 1;
const STOP_TRUNCATED = 2;
const STOP_NO_MODULE = 3;
const STOP_NO_FUNCTION = 4;
const STOP_UNSUPPORTED = 5;
const STOP_OUTSIDE = 6;
const STOP_STUCK = 7;
const STOP_INVALID = 8;
const STOP_BAD_FP = 9;
const STOP_CHAIN = 10;

const WalkSlot = extern struct {
    active: u64,
    walks: u64,
    kernel_walks: u64,
    // The walk in progress.
    pc: u64,
    sp: u64,
    bp: u64,
    first: u64,
    fp_steps: u64,
    // The inputs of the last walk, so that the test can redo it.
    start_pc: u64,
    start_sp: u64,
    start_bp: u64,
    kernel: u64,
    leaf_is_return: u64,
    code_before: u64,
    snapshot_len: u64,
    // The result of the last walk.
    count: u64,
    stop: u64,
    /// Identity of the walked stack: see `hashStack` in unwind/compactwalk.zig.
    hash: u64,
    stops: [16]u64,
    frames: [MAX_FRAMES]u64,
    snapshot: [SNAPSHOT_CHUNK * SNAPSHOT_CHUNKS / 8]u64,
};

comptime {
    if (@sizeOf(WalkSlot) != 17680) @compileError("WalkSlot size changed: update unwindprobe.zig too");
}

export var walk_progs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

export var walk_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(WalkSlot),
    .max_entries = MAX_CPUS,
};

/// The finalizer of splitmix64: a cheap way to make every bit of the input count.
inline fn mix(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

inline fn finishWalk(slot: *WalkSlot, reason: u64) void {
    slot.active = 0;
    slot.walks += 1;
    slot.stop = reason;
    slot.hash = mix(slot.hash ^ ((reason << 1) | slot.leaf_is_return));
    if (reason < 16) slot.stops[reason] += 1;
}

/// Copies the top of the user stack, chunk by chunk, until a read fails.
inline fn takeSnapshot(slot: *WalkSlot, sp: u64) void {
    slot.snapshot_len = 0;
    inline for (0..SNAPSHOT_CHUNKS) |i| {
        const words = SNAPSHOT_CHUNK / 8;
        if (bpf_probe_read_user(&slot.snapshot[i * words], SNAPSHOT_CHUNK, sp +% @as(u64, i * SNAPSHOT_CHUNK)) != 0) return;
        slot.snapshot_len = (i + 1) * SNAPSHOT_CHUNK;
    }
}

/// Where a step led: a stop reason (not 0), or the registers of the caller.
const Hop = struct { stop: u64, pc: u64, sp: u64, bp: u64 };

/// The standard frame: the frame pointer points at the saved frame pointer of the caller, and
/// the return address is above it. Only right for a function that has set up its frame.
fn framePointerStep(sp: u64, fp: u64) Hop {
    var out = Hop{ .stop = 0, .pc = 0, .sp = 0, .bp = 0 };
    if (fp == 0) { // the conventional end of a frame pointer chain
        out.stop = STOP_END;
        return out;
    }
    // A real frame lies above the stack pointer, on an 8 byte boundary.
    if (fp < sp or fp % 8 != 0 or fp > 0xffff_ffff_ffff_ffef) {
        out.stop = STOP_BAD_FP;
        return out;
    }
    var pair: [2]u64 = undefined;
    if (bpf_probe_read_user(&pair, 16, fp) != 0) {
        out.stop = STOP_OUTSIDE;
        return out;
    }
    out.bp = pair[0];
    out.pc = pair[1];
    out.sp = fp + 16;
    return out;
}

/// Walks up to FRAMES_PER_CALL frames of the walk in `slot`. Returns 0 when this call's budget
/// is used up and the walk goes on, or the STOP_* reason when the walk ended. The test program
/// and the production one share it: their slots have the same walk fields.
inline fn walkFrames(slot: anytype, tgid: u32) u64 {
    var k: u32 = 0;
    while (k < FRAMES_PER_CALL) : (k += 1) {
        const count = slot.count;
        if (count >= MAX_FRAMES) return STOP_TRUNCATED;
        const pc = slot.pc;
        const sp = slot.sp;
        const bp = slot.bp;

        // The first pc is where the thread was (or, in a system call, a return address); every
        // other one is a return address, which points just after a call.
        const at = if (slot.first != 0) pc else pc -% 1;
        const found = @call(.always_inline, findRow, .{ tgid, at });

        // In no mapping at all: the first address is kept, any other is not a return address.
        if (found.why == 1 or found.why == 2) {
            if (count != 0) return STOP_INVALID;
            slot.frames[0] = pc;
            slot.count = 1;
            slot.hash = mix(slot.hash ^ pc);
            return STOP_NO_MODULE;
        }
        slot.frames[count] = pc;
        slot.count = count + 1;
        slot.hash = mix(slot.hash ^ pc);

        var hop = Hop{ .stop = 0, .pc = 0, .sp = 0, .bp = 0 };
        var used_frame_pointer = false;
        if (found.why == 0) {
            const next = @call(.always_inline, stepOnce, .{ found.row, pc, sp, bp });
            if (next.kind == STEP_CALLER) {
                hop.pc = next.pc;
                hop.sp = next.sp;
                hop.bp = next.bp;
            } else if (next.kind == STEP_END) {
                hop.stop = STOP_END;
            } else if (next.kind == STEP_OUTSIDE) {
                hop.stop = STOP_OUTSIDE;
            } else {
                hop.stop = STOP_UNSUPPORTED;
            }
        } else if (found.why == 4 and bp == 0) {
            // Tables cover the module, but no function covers the address.
            hop.stop = STOP_NO_FUNCTION;
        } else {
            used_frame_pointer = true;
            hop = @call(.always_inline, framePointerStep, .{ sp, bp });
        }

        if (hop.stop != 0) return hop.stop;
        if (hop.pc == 0) return STOP_END;
        if (hop.sp <= sp) return STOP_STUCK;
        if (used_frame_pointer) slot.fp_steps += 1;
        slot.pc = hop.pc;
        slot.sp = hop.sp;
        slot.bp = hop.bp;
        slot.first = 0;
    }
    return 0;
}

export fn walkProbe(ctx: *anyopaque) linksection("perf_event/walk") c_int {
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&walk_debug, &cpu) orelse return 0;
    const slot: *WalkSlot = @ptrCast(@alignCast(slot_ptr));

    if (slot.active == 0) {
        const task = bpf_get_current_task_btf() orelse return 0;
        const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
        const regs: *const PtRegs = @ptrCast(@alignCast(regs_ptr));
        const sampled: *const PtRegs = @ptrCast(@alignCast(ctx));

        slot.active = 1;
        slot.pc = regs.ip;
        slot.sp = regs.sp;
        slot.bp = regs.bp;
        slot.start_pc = regs.ip;
        slot.start_sp = regs.sp;
        slot.start_bp = regs.bp;
        slot.count = 0;
        slot.fp_steps = 0;
        slot.hash = 0;
        takeSnapshot(slot, regs.sp);

        // The 8 bytes of code before the pc: `syscall` is 0f 05, a call starts with e8.
        slot.code_before = 0;
        _ = bpf_probe_read_user(&slot.code_before, 8, regs.ip -% 8);

        // A sample in user mode is exactly at the instruction being executed. In kernel mode
        // there are two cases: inside a system call, where the user ip is the address after the
        // `syscall` instruction (a return address like all the others), and an exception such
        // as a page fault, where it is the faulting instruction itself.
        const in_user_mode = (sampled.cs & 3) == 3;
        const after_syscall = (slot.code_before >> 48) == 0x050f;
        const leaf_is_return = !in_user_mode and after_syscall;
        slot.first = if (leaf_is_return) 0 else 1;
        slot.leaf_is_return = if (leaf_is_return) 1 else 0;
        slot.kernel = if (in_user_mode) 0 else 1;
        if (!in_user_mode) slot.kernel_walks += 1;
    }

    const reason = walkFrames(slot, tgid);
    if (reason != 0) {
        finishWalk(slot, reason);
        return 0;
    }

    _ = bpf_tail_call(ctx, &walk_progs, 0);
    // Only reached when the jump was refused.
    finishWalk(slot, STOP_CHAIN);
    return 0;
}

// ---- Step 1e-c1: records through a ring buffer ----

const bpf_ringbuf_output: *align(1) const fn (*const anyopaque, *const anyopaque, u64, u64) callconv(.c) c_long = @ptrFromInt(BPF.GET.RINGBUF_OUTPUT);

const RING_BYTES = 256 * 1024;

/// All CPUs write into this one buffer. Its size is `max_entries`, in bytes.
export var ring: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.RINGBUF,
    .key_size = 0,
    .value_size = 0,
    .max_entries = RING_BYTES,
};

/// What `ringProbe` sends for every sample. `seq` counts the records this CPU has sent.
const RingRecord = extern struct { seq: u64, pc: u64, tgid: u32, cpu: u32 };

/// Per CPU, written only by that CPU's samples.
const RingSlot = extern struct {
    /// The sequence number of the next record.
    seq: u64,
    sent: u64,
    /// Samples whose record did not fit: the ring was full.
    dropped: u64,
};

export var ring_debug: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(RingSlot),
    .max_entries = MAX_CPUS,
};

export fn ringProbe(ctx: *anyopaque) linksection("perf_event/ring") c_int {
    _ = ctx;
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    var cpu: u32 = bpf_get_smp_processor_id();
    if (cpu >= MAX_CPUS) return 0;
    const slot_ptr = bpf_map_lookup_elem(&ring_debug, &cpu) orelse return 0;
    const slot: *RingSlot = @ptrCast(@alignCast(slot_ptr));

    const task = bpf_get_current_task_btf() orelse return 0;
    const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
    const regs: *const PtRegs = @ptrCast(@alignCast(regs_ptr));

    var record = RingRecord{ .seq = slot.seq, .pc = regs.ip, .tgid = tgid, .cpu = cpu };
    if (bpf_ringbuf_output(&ring, &record, @sizeOf(RingRecord), 0) != 0) {
        slot.dropped += 1;
        return 0;
    }
    // The number only moves when the record was sent, so the records that arrive have no gaps.
    slot.seq += 1;
    slot.sent += 1;
    return 0;
}

// ---- Step 1e-c2a: the production walk ----

const HEADER_BYTES = 16;

/// Room for the kernel part of a stack. It is written right after the user frames.
const MAX_KFRAMES = 32;

/// long bpf_get_stack(void *ctx, void *buf, u32 size, u64 flags): bytes written, or negative.
const bpf_get_stack: *align(1) const fn (*anyopaque, *anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(67);

/// The state of the production walk on one CPU. The last part is the record that goes into the
/// ring: a header and then the frames, which has to stay in this order.
const OncpuSlot = extern struct {
    // The walk in progress.
    active: u64,
    pc: u64,
    sp: u64,
    bp: u64,
    first: u64,
    fp_steps: u64,
    leaf_is_return: u64,
    hash: u64,
    count: u64,
    // Counters, since the program was loaded.
    walks: u64,
    kernel_walks: u64,
    sent: u64,
    /// Walks whose record did not fit in the ring.
    dropped: u64,
    repeats: u64,
    map_full: u64,
    stops: [16]u64,
    // The record.
    rec_hash: u64,
    rec_tgid: u32,
    rec_count: u8,
    /// Kernel frames, stored right after the `rec_count` user frames.
    rec_kcount: u8,
    rec_stop: u8,
    /// Bit 0: the first frame is a return address. Bit 1: the sample was taken in kernel mode.
    /// Bit 2: the kernel part filled all the room it has, so it may be cut.
    rec_flags: u8,
    frames: [MAX_FRAMES + MAX_KFRAMES]u64,
};

comptime {
    if (@sizeOf(OncpuSlot) != 1544 or @offsetOf(OncpuSlot, "frames") != @offsetOf(OncpuSlot, "rec_hash") + HEADER_BYTES)
        @compileError("OncpuSlot layout changed: update the userspace side too");
}

export var oncpu_state: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PERCPU_ARRAY,
    .key_size = 4,
    .value_size = @sizeOf(OncpuSlot),
    .max_entries = 1,
};

export var oncpu_progs: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.PROG_ARRAY,
    .key_size = 4,
    .value_size = 4,
    .max_entries = 1,
};

/// Identifies a stack inside one process. The count of each key is how often the stack was seen.
const CountKey = extern struct {
    hash: u64,
    tgid: u32,
    reserved: u32,
};

export var oncpu_counts: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.HASH,
    .key_size = @sizeOf(CountKey),
    .value_size = 8,
    .max_entries = 8192,
};

inline fn addOne(value: *anyopaque) void {
    _ = @atomicRmw(u64, @as(*u64, @ptrCast(@alignCast(value))), .Add, 1, .monotonic);
}

inline fn finishOncpu(ctx: *anyopaque, slot: *OncpuSlot, tgid: u32, reason: u64) void {
    slot.active = 0;
    slot.walks += 1;
    if (reason < 16) slot.stops[reason] += 1;

    var count = slot.count;
    if (count > MAX_FRAMES) count = MAX_FRAMES;
    slot.rec_count = @truncate(count);

    // A sample taken in kernel mode also gets the kernel stack, right after the user frames.
    var h = slot.hash;
    var kcount: u64 = 0;
    if ((slot.rec_flags & 2) != 0) {
        const got = bpf_get_stack(ctx, &slot.frames[count], MAX_KFRAMES * 8, 0);
        if (got > 0) {
            kcount = @as(u64, @intCast(got)) / 8;
            if (kcount > MAX_KFRAMES) kcount = MAX_KFRAMES;
            var i: u64 = 0;
            while (i < kcount) : (i += 1) {
                h = mix(h ^ slot.frames[count + i]);
            }
            if (kcount == MAX_KFRAMES) slot.rec_flags |= 4;
        }
    }
    slot.rec_kcount = @truncate(kcount);

    slot.rec_hash = mix(h ^ ((reason << 1) | slot.leaf_is_return));
    slot.rec_tgid = tgid;
    slot.rec_stop = @truncate(reason);

    var key = CountKey{ .hash = slot.rec_hash, .tgid = tgid, .reserved = 0 };

    // A stack seen before is only counted. Its frames are already in the ring.
    if (bpf_map_lookup_elem(&oncpu_counts, &key)) |seen| {
        addOne(seen);
        slot.repeats += 1;
        return;
    }

    const size: u64 = HEADER_BYTES + (count + kcount) * 8;
    if (bpf_ringbuf_output(&ring, &slot.rec_hash, size, 0) != 0) {
        // Not inserted, so the next sample of this stack sends it again.
        slot.dropped += 1;
        return;
    }
    slot.sent += 1;

    var one: u64 = 1;
    if (bpf_map_update_elem(&oncpu_counts, &key, &one, BPF.NOEXIST) != 0) {
        if (bpf_map_lookup_elem(&oncpu_counts, &key)) |seen| {
            addOne(seen);
        } else {
            slot.map_full += 1;
        }
    }
}
export fn oncpuWalk(ctx: *anyopaque) linksection("perf_event/oncpu_walk") c_int {
    var zero: u32 = 0;
    const target_ptr = bpf_map_lookup_elem(&target_pid, &zero) orelse return 0;
    const pid = @as(*const u32, @ptrCast(@alignCast(target_ptr)));
    if (pid.* == 0) return 0;
    const tgid: u32 = @truncate(bpf_get_current_pid_tgid() >> 32);
    if (tgid != pid.*) return 0;

    // A per-CPU map: this is the copy of the CPU the program runs on.
    const slot_ptr = bpf_map_lookup_elem(&oncpu_state, &zero) orelse return 0;
    const slot: *OncpuSlot = @ptrCast(@alignCast(slot_ptr));

    if (slot.active == 0) {
        const task = bpf_get_current_task_btf() orelse return 0;
        const regs_ptr = bpf_task_pt_regs(task) orelse return 0;
        const regs: *const PtRegs = @ptrCast(@alignCast(regs_ptr));
        const sampled: *const PtRegs = @ptrCast(@alignCast(ctx));

        slot.active = 1;
        slot.pc = regs.ip;
        slot.sp = regs.sp;
        slot.bp = regs.bp;
        slot.count = 0;
        slot.fp_steps = 0;
        slot.hash = 0;

        // The same rule as the test program: in a system call the user ip is a return address.
        var code_before: u64 = 0;
        _ = bpf_probe_read_user(&code_before, 8, regs.ip -% 8);
        const in_user_mode = (sampled.cs & 3) == 3;
        const after_syscall = (code_before >> 48) == 0x050f;
        const leaf_is_return = !in_user_mode and after_syscall;
        slot.first = if (leaf_is_return) 0 else 1;
        slot.leaf_is_return = if (leaf_is_return) 1 else 0;
        slot.rec_flags = (if (leaf_is_return) @as(u8, 1) else 0) | (if (in_user_mode) @as(u8, 0) else 2);
        if (!in_user_mode) slot.kernel_walks += 1;
    }

    const reason = walkFrames(slot, tgid);
    if (reason != 0) {
        finishOncpu(ctx, slot, tgid, reason);
        return 0;
    }

    _ = bpf_tail_call(ctx, &oncpu_progs, 0);
    // Only reached when the jump was refused.
    finishOncpu(ctx, slot, tgid, STOP_CHAIN);
    return 0;
}

export const LICENSE: [4]u8 linksection("license") = .{ 'G', 'P', 'L', 0 };
