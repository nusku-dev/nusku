pub const MAX_STACK_FRAMES = 128;
/// Maximum number of kernel frames appended to a user stack.
pub const MAX_KERNEL_STACK_FRAMES = 32;

pub const STOP_REASON_COUNT = 16;

pub const RecordHeader = extern struct {
    stack_hash: u64,
    tgid: u32,
    user_frame_count: u8,
    kernel_frame_count: u8,
    stop_reason: u8,
    flags: u8,
};

pub const flag_initial_pc_is_return_address: u8 = 1 << 0;
pub const flag_sampled_in_kernel_mode: u8 = 1 << 1;
pub const flag_kernel_frames_truncated: u8 = 1 << 2;

pub const flags_known: u8 =
    flag_initial_pc_is_return_address |
    flag_sampled_in_kernel_mode |
    flag_kernel_frames_truncated;

comptime {
    if (@sizeOf(RecordHeader) != 16) {
        @compileError("RecordHeader must be 16 bytes: the wire format depends on it");
    }
    // Frames are u64 and follow the header directly, so the header must keep them aligned.
    if (@sizeOf(RecordHeader) % 8 != 0) {
        @compileError("RecordHeader size must be a multiple of 8");
    }
    // Frame counts are u8 on the wire.
    if (MAX_STACK_FRAMES > 255 or MAX_KERNEL_STACK_FRAMES > 255) {
        @compileError("Frame limits must fit in a u8");
    }
}

/// Per-CPU state for a production stack sample.
///
/// The record fields must remain contiguous:
/// stack_hash, process ID, frame counts, stop reason, flags, then frames.
/// The ring buffer receives this record starting at `stack_hash`.
pub const OnCpuStackState = extern struct {
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
    stop_reason_counts: [STOP_REASON_COUNT]u64,

    // Record header, followed immediately by the frame addresses.
    record: RecordHeader,
    stack_frames: [MAX_STACK_FRAMES + MAX_KERNEL_STACK_FRAMES]u64,
};

comptime {
    if (@offsetOf(OnCpuStackState, "stack_frames") !=
        @offsetOf(OnCpuStackState, "record") + @sizeOf(RecordHeader))
    {
        @compileError("Stack record header and frame addresses must be contiguous");
    }
}

/// Identifies one unique stack within a process.
pub const StackCountKey = extern struct {
    stack_hash: u64,
    tgid: u32,
    reserved: u32,
};
