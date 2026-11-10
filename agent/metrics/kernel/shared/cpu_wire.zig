//! What the on-CPU sampler and the agent exchange.

pub const user_frames_max: u32 = 128;
pub const kernel_frames_max: u32 = 32;
pub const frames_max: u32 = user_frames_max + kernel_frames_max;

/// Four keeps one run well inside the verifier's complexity limit.
pub const frames_per_run: u32 = 4;
/// The kernel allows 33 tail calls in a chain (MAX_TAIL_CALL_CNT), so a walk has 34 runs.
pub const tail_calls_max: u32 = 33;

pub const counts_max: u32 = 16384;

pub const records_bytes: u32 = 512 * 1024;

pub const Config = extern struct {
    tgid: u32,
    generation: u32,
};

pub const StopReason = enum(u8) {
    none = 0,
    end = 1,
    truncated = 2,
    no_mapping = 3,
    no_function_info = 4,
    unsupported_unwind = 5,
    stack_read_failed = 6,
    stack_pointer_stuck = 7,
    invalid_stack = 8,
    invalid_frame_pointer = 9,
    tail_call_failed = 10,
};

pub const stop_reason_count: u32 = 16;

pub const RecordHeader = extern struct {
    stack_hash: u64,
    tgid: u32,
    user_frame_count: u8,
    kernel_frame_count: u8,
    stop_reason: u8,
    flags: u8,
};

pub const record_flag_leaf_is_return: u8 = 1 << 0;
pub const record_flag_kernel_mode: u8 = 1 << 1;
pub const record_flag_kernel_truncated: u8 = 1 << 2;
pub const record_flags_known: u8 =
    record_flag_leaf_is_return | record_flag_kernel_mode | record_flag_kernel_truncated;

pub const CountKey = extern struct {
    stack_hash: u64,
    tgid: u32,
    generation: u32,
};

pub const WalkState = extern struct {
    walk_in_progress: u64,
    walk_pid_tgid: u64,
    pc: u64,
    sp: u64,
    bp: u64,
    pc_is_leaf: u64,
    leaf_is_return: u64,
    stack_hash: u64,
    frame_count: u64,
    frame_pointer_steps: u64,

    walks_completed: u64,
    walks_from_kernel: u64,
    walks_abandoned: u64,
    records_sent: u64,
    records_dropped: u64,
    stacks_repeated: u64,
    counts_insert_failed: u64,
    stop_counts: [stop_reason_count]u64,

    record: RecordHeader,
    stack_frames: [frames_max]u64,
};

comptime {
    if (@sizeOf(Config) != 8) @compileError("Config must be 8 bytes");
    if (@sizeOf(CountKey) != 16) @compileError("CountKey must be 16 bytes");
    if (@sizeOf(RecordHeader) != 16) @compileError("RecordHeader must be 16 bytes");
    if (@sizeOf(RecordHeader) % 8 != 0) @compileError("RecordHeader must keep frames aligned");
    if (@offsetOf(WalkState, "stack_frames") !=
        @offsetOf(WalkState, "record") + @sizeOf(RecordHeader))
    {
        @compileError("the record header and its frames must be adjacent");
    }

    if (user_frames_max > 255) @compileError("user_frames_max must fit in a u8");
    if (kernel_frames_max > 255) @compileError("kernel_frames_max must fit in a u8");
    if ((tail_calls_max + 1) * frames_per_run < user_frames_max) {
        @compileError("the tail call chain cannot reach user_frames_max");
    }
    if (@intFromEnum(StopReason.tail_call_failed) >= stop_reason_count) {
        @compileError("every stop reason needs a counter");
    }
    if (records_bytes & (records_bytes - 1) != 0) @compileError("records_bytes: power of two");
    if (records_bytes % 4096 != 0) @compileError("records_bytes: multiple of the page size");
}
