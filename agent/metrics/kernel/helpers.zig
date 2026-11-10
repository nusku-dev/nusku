//! The kernel helpers and map definitions of the BPF programs.

pub const map_lookup_elem: *align(1) const fn (
    map: *const anyopaque,
    key: *const anyopaque,
) callconv(.c) ?*anyopaque = @ptrFromInt(1);

pub const map_update_elem: *align(1) const fn (
    map: *const anyopaque,
    key: *const anyopaque,
    value: *const anyopaque,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(2);

pub const get_smp_processor_id: *align(1) const fn () callconv(.c) u32 = @ptrFromInt(8);

pub const tail_call: *align(1) const fn (
    context: *anyopaque,
    prog_array_map: *const anyopaque,
    index: u32,
) callconv(.c) c_long = @ptrFromInt(12);

pub const get_current_pid_tgid: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(14);

pub const get_stackid: *align(1) const fn (
    context: *anyopaque,
    map: *const anyopaque,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(27);

pub const get_stack: *align(1) const fn (
    context: *anyopaque,
    buffer: *anyopaque,
    size: u32,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(67);

pub const probe_read_user: *align(1) const fn (
    target: *anyopaque,
    size: u32,
    source_address: u64,
) callconv(.c) c_long = @ptrFromInt(112);

pub const ringbuf_output: *align(1) const fn (
    ringbuf: *const anyopaque,
    data: *const anyopaque,
    size: u64,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(130);

/// The current task, as a pointer the verifier can follow (Linux 5.11+).
pub const get_current_task_btf: *align(1) const fn () callconv(.c) ?*anyopaque = @ptrFromInt(158);

pub const task_pt_regs: *align(1) const fn (task: *anyopaque) callconv(.c) ?*anyopaque =
    @ptrFromInt(175);

pub const update_any: u64 = 0;
pub const update_no_exist: u64 = 1;

pub const stack_user: u64 = 1 << 8;
pub const stack_fast_compare: u64 = 1 << 9;

pub const ringbuf_no_wakeup: u64 = 1;

pub const MapType = struct {
    pub const hash: u32 = 1;
    pub const array: u32 = 2;
    pub const prog_array: u32 = 3;
    pub const percpu_array: u32 = 6;
    pub const stack_trace: u32 = 7;
    pub const ringbuf: u32 = 27;
};

pub const MapDef = extern struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
};

comptime {
    if (@sizeOf(MapDef) != 16) @compileError("MapDef must be 16 bytes");
}

pub const Registers = extern struct {
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
    if (@sizeOf(Registers) != 21 * 8) @compileError("Registers must match struct pt_regs");
}
