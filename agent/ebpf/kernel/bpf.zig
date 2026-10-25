// https://man7.org/linux/man-pages/man7/bpf-helpers.7.html
// https://man7.org/linux/man-pages/man2/bpf.2.html

pub const BPF = struct {
    /// insert only if the key doesn't already exist.
    pub const NOEXIST: u64 = 1;

    /// FUNC: struct pt_regs *bpf_task_pt_regs(struct task_struct *task)
    /// Description: The user-space registers saved when `task` entered the kernel (Linux 5.15+).
    pub const TASK_PT_REGS = 175;
    pub const task_pt_regs: *align(1) const fn (*anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(175);

    /// FUNC: long bpf_probe_read_user(void *dst, u32 size, const void *unsafe_ptr)
    /// Description: Copies `size` bytes from a user-space address; fails instead of faulting.
    pub const PROBE_READ_USER = 112;
    pub const probe_read_user: *align(1) const fn (*anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(112);

    /// FUNC: long bpf_tail_call(void *ctx, struct bpf_map *prog_array_map, u32 index)
    /// Description: Jumps into the program stored at `index`; returns only if the jump fails.
    pub const TAIL_CALL = 12;
    pub const tail_call: *align(1) const fn (*anyopaque, *anyopaque, u32) callconv(.c) c_long = @ptrFromInt(12);

    /// FUNC: long bpf_ringbuf_output(void *ringbuf, void *data, u64 size, u64 flags)
    /// Description: Copies `size` bytes into the ring buffer; fails with a negative number when it is full.
    pub const RINGBUF_OUTPUT = 130;
    pub const ringbuf_output: *align(1) const fn (*const anyopaque, *const anyopaque, u64, u64) callconv(.c) c_long = @ptrFromInt(130);

    pub const MAP = struct {
        pub const TYPE = struct {
            /// stores key/value pairs, like a hash table.
            pub const HASH = 1;
            /// fixed-size BPF map where key 0 always accesses the single slot
            pub const ARRAY = 2;
            /// stores eBPF program references at integer indexes,
            pub const PROG_ARRAY = 3;
            /// like ARRAY, but every CPU has its own copy of every value
            pub const PERCPU_ARRAY = 6;
            /// special BPF map for storing stack traces.
            pub const STACK_TRACE = 7;
            /// a ring buffer shared by all CPUs; the program copies records into it
            pub const RINGBUF = 27;
        };

        /// FUNC: void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)
        /// Description: Perform a lookup in map for an entry associated to key
        /// Return Map value associated to key, or NULL if no entry was found.
        pub const LOOKUP_ELEM = 1;
        pub const lookup_elem: *align(1) const fn (*const anyopaque, *const anyopaque) callconv(.c) ?*anyopaque = @ptrFromInt(1);
        /// FUNC: long bpf_map_update_elem(struct bpf_map *map, const void *key, const void *value, u64 flags)
        /// Description:
        /// Add or update the value of the entry associated to key in map with value.
        /// flags is one of:
        ///       BPF_NOEXIST : The entry for key must not exist in the map.
        ///       BPF_EXIST : The entry for key must already exist in the map.
        ///       BPF_ANY : No condition on the existence of the entry for key.
        ///
        /// Flag value BPF_NOEXIST cannot be used for maps of
        /// types BPF_MAP_TYPE_ARRAY or
        /// BPF_MAP_TYPE_PERCPU_ARRAY  (all elements always
        /// exist), the helper would return an error.
        pub const UPDATE_ELEM = 2;
        pub const update_elem: *align(1) const fn (*const anyopaque, *const anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(2);
    };
    pub const GET = struct {
        /// FUNC: long bpf_get_stackid(void *ctx, struct bpf_map *map, u64 flags)
        /// Description:
        ///        Walk a user or a kernel stack and return its id. To
        ///        achieve this, the helper needs ctx, which is a
        ///        pointer to the context on which the tracing program
        ///        is executed, and a pointer to a map of type BPF_MAP_TYPE_STACK_TRACE.
        ///
        /// -------------------
        ///       The last argument, flags, holds the number of stack
        ///       frames to skip (from 0 to 255), masked with
        ///       BPF_F_SKIP_FIELD_MASK. The next bits can be used to
        ///       set a combination of the following flags:
        ///        BPF_F_USER_STACK
        ///               Collect a user space stack instead of a
        ///               kernel stack.
        ///        BPF_F_FAST_STACK_CMP
        ///               Compare stacks by hash only.
        ///        BPF_F_REUSE_STACKID
        ///               If two different stacks hash into the same
        ///               stackid, discard the old one.
        ///        The stack id retrieved is a 32 bit long integer
        ///        handle which can be further combined with other data
        ///        (including other stack ids) and used as a key into
        ///        maps. This can be useful for generating a variety of
        ///        graphs (such as flame graphs or off-cpu graphs).
        /// Return The positive or null stack id on success, or a negative error in case of failure.
        pub const STACKID = 27;
        pub const stackid: *align(1) const fn (*anyopaque, *const anyopaque, u64) callconv(.c) c_long = @ptrFromInt(27);

        /// FUNC: u64 bpf_get_current_pid_tgid(void)
        /// Description: Get the current pid and tgid.
        /// Return A 64-bit integer containing the current tgid and pid, and created as such:
        ///        current_task->tgid << 32 |
        ///        current_task->pid.
        pub const CURRENT_PID_TGID = 14;
        pub const current_pid_tgid: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(14);

        /// FUNC: u32 bpf_get_smp_processor_id(void)
        pub const SMP_PROCESSOR_ID = 8;
        pub const smp_processor_id: *align(1) const fn () callconv(.c) u32 = @ptrFromInt(8);

        /// FUNC: struct task_struct *bpf_get_current_task_btf(void)
        /// Description: The current task as a pointer the verifier can follow (kernel BTF).
        pub const CURRENT_TASK_BTF = 158;
        pub const current_task_btf: *align(1) const fn () callconv(.c) ?*anyopaque = @ptrFromInt(158);

        ///FUNC: long bpf_get_stack(void *ctx, void *buf, u32 size, u64 flags)
        ///bytes written, or negative.
        pub const STACK = 67;
        pub const stack: *align(1) const fn (*anyopaque, *anyopaque, u32, u64) callconv(.c) c_long = @ptrFromInt(67);
    };

    pub const F = struct {
        /// Collect a user space stack instead of a kernel stack.
        /// The task must be the current task.
        pub const USER_STACK: u64 = 1 << 8; // 256
        /// Compare stacks by hash only.
        pub const FAST_STACK_CMP: u64 = 1 << 9; // 512
    };
};

// -- maps --
// The loader reads these 16 bytes straight out of the .maps section and creates the map

pub const MapDef = extern struct {
    /// what kind of map to create.
    map_type: u32,
    /// how many bytes each key occupies.
    key_size: u32,
    /// how many bytes each value occupies.
    value_size: u32,
    /// the maximum number of entries.
    max_entries: u32,
};
