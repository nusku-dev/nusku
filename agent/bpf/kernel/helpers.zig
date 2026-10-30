//! The kernel helpers and map definitions the BPF programs use, written for Zig.
//!
//! A helper is called through a pointer whose value is its number: the verifier rewrites the
//! call into the real function. The names follow the C names in bpf-helpers(7), so the man page
//! can be searched for each one:
//! https://man7.org/linux/man-pages/man7/bpf-helpers.7.html

/// void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)
/// The value for `key`, or null if the map has none.
pub const map_lookup_elem: *align(1) const fn (
    map: *const anyopaque,
    key: *const anyopaque,
) callconv(.c) ?*anyopaque = @ptrFromInt(1);

/// long bpf_map_update_elem(struct bpf_map *map, const void *key, const void *value, u64 flags)
/// 0, or a negative error. `update_no_exist` fails if the key is present already.
pub const map_update_elem: *align(1) const fn (
    map: *const anyopaque,
    key: *const anyopaque,
    value: *const anyopaque,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(2);

/// u32 bpf_get_smp_processor_id(void)
pub const get_smp_processor_id: *align(1) const fn () callconv(.c) u32 = @ptrFromInt(8);

/// long bpf_tail_call(void *ctx, struct bpf_map *prog_array_map, u32 index)
/// Jumps into the program at `index`. Returns only if the jump fails.
pub const tail_call: *align(1) const fn (
    context: *anyopaque,
    prog_array_map: *const anyopaque,
    index: u32,
) callconv(.c) c_long = @ptrFromInt(12);

/// u64 bpf_get_current_pid_tgid(void)
/// The current task as tgid << 32 | pid.
pub const get_current_pid_tgid: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(14);

/// long bpf_get_stackid(void *ctx, struct bpf_map *map, u64 flags)
/// The id of the current stack in a stack trace map, or a negative error.
pub const get_stackid: *align(1) const fn (
    context: *anyopaque,
    map: *const anyopaque,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(27);

/// long bpf_get_stack(void *ctx, void *buf, u32 size, u64 flags)
/// Bytes written to `buf`, or a negative error.
pub const get_stack: *align(1) const fn (
    context: *anyopaque,
    buffer: *anyopaque,
    size: u32,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(67);

/// long bpf_probe_read_user(void *dst, u32 size, const void *unsafe_ptr)
/// Copies `size` bytes from a user address. Fails instead of faulting: 0, or a negative error.
pub const probe_read_user: *align(1) const fn (
    target: *anyopaque,
    size: u32,
    source_address: u64,
) callconv(.c) c_long = @ptrFromInt(112);

/// long bpf_ringbuf_output(void *ringbuf, void *data, u64 size, u64 flags)
/// Copies `size` bytes into the ring buffer: 0, or a negative error when it is full.
pub const ringbuf_output: *align(1) const fn (
    ringbuf: *const anyopaque,
    data: *const anyopaque,
    size: u64,
    flags: u64,
) callconv(.c) c_long = @ptrFromInt(130);

/// struct task_struct *bpf_get_current_task_btf(void)
/// The current task, as a pointer the verifier can follow (Linux 5.11+).
pub const get_current_task_btf: *align(1) const fn () callconv(.c) ?*anyopaque = @ptrFromInt(158);

/// struct pt_regs *bpf_task_pt_regs(struct task_struct *task)
/// The user registers saved when `task` entered the kernel (Linux 5.15+).
pub const task_pt_regs: *align(1) const fn (task: *anyopaque) callconv(.c) ?*anyopaque =
    @ptrFromInt(175);

/// `map_update_elem` flags.
pub const update_any: u64 = 0;
pub const update_no_exist: u64 = 1;

/// `get_stackid` and `get_stack` flags.
pub const stack_user: u64 = 1 << 8;
pub const stack_fast_compare: u64 = 1 << 9;

/// `ringbuf_output` flag: do not wake the reader. The agent drains the ring on its own timer,
/// so a wakeup per record would only cost the sampled CPU an interrupt.
pub const ringbuf_no_wakeup: u64 = 1;

/// The map types the programs use (enum bpf_map_type).
pub const MapType = struct {
    pub const hash: u32 = 1;
    pub const array: u32 = 2;
    pub const prog_array: u32 = 3;
    pub const percpu_array: u32 = 6;
    pub const stack_trace: u32 = 7;
    pub const ringbuf: u32 = 27;
};

/// A map as declared in the `.maps` section. The agent's loader reads these 16 bytes straight
/// out of the object and creates the map from them.
pub const MapDef = extern struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
};

comptime {
    // bpf/object.zig reads exactly these 16 bytes per map.
    if (@sizeOf(MapDef) != 16) @compileError("MapDef must be 16 bytes");
}

/// The user registers of x86-64 Linux (struct pt_regs), in the kernel's order.
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
