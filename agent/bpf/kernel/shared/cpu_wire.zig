//! What the on-CPU sampler and the agent exchange: the config the agent writes, the records the
//! program sends through the ring buffer, the keys it counts stacks under, and its per-CPU state.
//!
//! This file is compiled into the kernel program (bpfel, freestanding) and into the agent, so it
//! holds only extern structs and constants, and does not import std.

pub const user_frames_max: u32 = 128;
/// Kernel frames appended after the user frames when a sample is taken in kernel mode.
pub const kernel_frames_max: u32 = 32;
pub const frames_max: u32 = user_frames_max + kernel_frames_max;

/// Frames unwound in one run of the program before it tail-calls itself. Four keeps one run
/// well inside the verifier's complexity limit.
pub const frames_per_run: u32 = 4;
/// The kernel allows 33 tail calls in a chain (MAX_TAIL_CALL_CNT), so a walk has 34 runs.
pub const tail_calls_max: u32 = 33;

/// Distinct stacks counted in one window. Sketch: 99 Hz on 64 CPUs for a 1 s window is at most
/// 6336 samples, so even if every sample were a new stack this holds 2.5 windows. Two
/// generations share the map while the older one is drained.
pub const counts_max: u32 = 16384;

/// The ring buffer. Sketch: a new stack's record is 16 + 8 * frames bytes, 400 bytes for a
/// typical 48-frame stack. The agent drains the ring every 100 ms, so 512 KiB holds about 1300
/// new stacks per drain, far above what a real workload sends (most samples repeat a stack).
pub const records_bytes: u32 = 512 * 1024;

/// Slot 0 of the config map. The agent writes it; the program only reads it.
pub const Config = extern struct {
    /// The process to sample. 0 samples nothing.
    tgid: u32,
    /// Stamped into every count key. The agent advances it at each report and then drains the
    /// keys of older generations, so the counts map only ever holds about one window.
    generation: u32,
};

/// Why the walk of a stack ended.
pub const StopReason = enum(u8) {
    /// Never written by the program: the numbering starts at 1 because 0 means "keep going".
    none = 0,
    /// The outermost frame was reached: the stack is complete.
    end = 1,
    /// `user_frames_max` frames were unwound and the stack goes on.
    truncated = 2,
    /// The first address is in no executable mapping the agent knows about.
    no_mapping = 3,
    /// Not written any more: an address without a row and with rbp 0 is the outermost frame
    /// (`end`). The value stays taken, so the numbers on the wire never change meaning.
    no_function_info = 4,
    /// The table row has rules the program cannot apply.
    unsupported_unwind = 5,
    /// Reading the user stack failed.
    stack_read_failed = 6,
    /// The caller's stack pointer is not above the callee's.
    stack_pointer_stuck = 7,
    /// An address after the first is in no known mapping.
    invalid_stack = 8,
    /// The frame pointer chain points somewhere it cannot.
    invalid_frame_pointer = 9,
    /// The program could not tail-call itself to continue.
    tail_call_failed = 10,
};

/// The size of every per-reason counter array. Above the largest reason, so a new reason fits.
pub const stop_reason_count: u32 = 16;

/// The start of every ring record. `user_frame_count + kernel_frame_count` u64 frames follow it.
pub const RecordHeader = extern struct {
    stack_hash: u64,
    tgid: u32,
    user_frame_count: u8,
    kernel_frame_count: u8,
    /// A `StopReason`, kept as a byte because the agent reads it from the kernel.
    stop_reason: u8,
    flags: u8,
};

/// The first user address is a return address (the sample interrupted a system call), not the
/// instruction that was running.
pub const record_flag_leaf_is_return: u8 = 1 << 0;
/// The sample was taken in kernel mode, so kernel frames follow the user frames.
pub const record_flag_kernel_mode: u8 = 1 << 1;
/// The kernel stack filled `kernel_frames_max` frames, so it may go on.
pub const record_flag_kernel_truncated: u8 = 1 << 2;
pub const record_flags_known: u8 =
    record_flag_leaf_is_return | record_flag_kernel_mode | record_flag_kernel_truncated;

/// One stack of one process in one generation. The value is the number of samples.
pub const CountKey = extern struct {
    stack_hash: u64,
    tgid: u32,
    generation: u32,
};

/// The per-CPU state of the program: the walk in progress, and counters for the whole run.
///
/// `record` and `stack_frames` must stay adjacent: the ring receives the bytes starting at
/// `record`, header and frames in one copy.
pub const WalkState = extern struct {
    /// 1 between the first run of a walk and its last.
    walk_in_progress: u64,
    /// The task the walk belongs to. A walk that meets another task was left behind.
    walk_pid_tgid: u64,
    pc: u64,
    sp: u64,
    bp: u64,
    /// 1 while `pc` is the sampled instruction, 0 once it is a return address.
    pc_is_leaf: u64,
    leaf_is_return: u64,
    stack_hash: u64,
    frame_count: u64,
    frame_pointer_steps: u64,

    // Counters for the whole run. The agent sums them over the CPUs.
    walks_completed: u64,
    walks_from_kernel: u64,
    /// Walks that were left unfinished and found by a later sample. Should stay 0.
    walks_abandoned: u64,
    records_sent: u64,
    /// The ring was full: the sample is lost.
    records_dropped: u64,
    /// The stack was counted already in this generation, so no record was needed.
    stacks_repeated: u64,
    /// The counts map was full: the record was sent but the sample is lost.
    counts_insert_failed: u64,
    stop_counts: [stop_reason_count]u64,

    record: RecordHeader,
    stack_frames: [frames_max]u64,
};

comptime {
    // The wire format: a change here is a change on both sides of the boundary.
    if (@sizeOf(Config) != 8) @compileError("Config must be 8 bytes");
    if (@sizeOf(CountKey) != 16) @compileError("CountKey must be 16 bytes");
    if (@sizeOf(RecordHeader) != 16) @compileError("RecordHeader must be 16 bytes");
    // Frames are u64 and follow the header directly, so the header keeps them aligned.
    if (@sizeOf(RecordHeader) % 8 != 0) @compileError("RecordHeader must keep frames aligned");
    if (@offsetOf(WalkState, "stack_frames") !=
        @offsetOf(WalkState, "record") + @sizeOf(RecordHeader))
    {
        @compileError("the record header and its frames must be adjacent");
    }

    // Frame counts travel as u8.
    if (user_frames_max > 255) @compileError("user_frames_max must fit in a u8");
    if (kernel_frames_max > 255) @compileError("kernel_frames_max must fit in a u8");
    // Every run of the chain together must be able to reach the frame limit.
    if ((tail_calls_max + 1) * frames_per_run < user_frames_max) {
        @compileError("the tail call chain cannot reach user_frames_max");
    }
    if (@intFromEnum(StopReason.tail_call_failed) >= stop_reason_count) {
        @compileError("every stop reason needs a counter");
    }
    // A ring buffer's size must be a power of two and a multiple of the page size.
    if (records_bytes & (records_bytes - 1) != 0) @compileError("records_bytes: power of two");
    if (records_bytes % 4096 != 0) @compileError("records_bytes: multiple of the page size");
}
