//! The frames of the stacks the kernel program sent through the ring buffer, kept until the
//! window that counts them is built. All memory is allocated at init and reused.
//!
//! Why two epochs. The kernel sends a stack's record before it inserts the stack's count key
//! (see bpf/kernel/cpu.bpf.zig), and the collector drains the counts before it reads the ring.
//! So every drained count finds its record in the ring, or earlier in the cache. A record can
//! arrive one report early: sent just before a report's drain, its key inserted just after it.
//! So a record must outlive the report after the one it arrived in, and no longer. Each report
//! starts a new epoch and forgets the epoch before the previous one:
//!
//!     report N-1: advance   drain   read ring -> epoch A   build window N-1 from A and B
//!     ticks:                        read ring -> epoch A
//!     report N:   advance (B forgotten, A kept)   drain   read ring -> epoch B
//!                 build window N from B and A
//!
//! The window refers to the frames in the cache instead of copying them, so the frames must stay
//! put until the next report: only `epoch_advance`, at the start of a report, forgets frames.

const std = @import("std");
const assert = std.debug.assert;
const cpu_wire = @import("../bpf/kernel/shared/cpu_wire.zig");

const RecordHeader = cpu_wire.RecordHeader;
const header_size = @sizeOf(RecordHeader);

/// A stack is known by its hash within its process: the kernel hashes the frames, the stop
/// reason and the kind of leaf.
pub const StackId = struct {
    hash: u64,
    tgid: u32,
};

/// One record, unpacked.
pub const Stack = struct {
    header: RecordHeader,
    /// The user frames, then the kernel frames: `header.user_frame_count` and
    /// `header.kernel_frame_count` of them.
    frames: []const u64,

    pub fn user(stack: *const Stack) []const u64 {
        assert(stack.frames.len == frame_count(stack.header));
        return stack.frames[0..stack.header.user_frame_count];
    }

    pub fn kernel(stack: *const Stack) []const u64 {
        assert(stack.frames.len == frame_count(stack.header));
        return stack.frames[stack.header.user_frame_count..];
    }
};

pub const FrameCache = struct {
    epochs: [2]Epoch,
    /// Records go into `epochs[current]`.
    current: u1,
    /// Records that failed validation. The kernel program writes them, so this should stay 0.
    records_malformed: u64,
    /// Records that found no room in the epoch. Their stacks' counts will miss their frames.
    records_overflow: u64,

    pub const Options = struct {
        /// Stacks per epoch: at most one per count key, so the counts map's size is enough.
        stacks_max: u32,
        /// Frames per epoch, over all its stacks.
        frames_max: u32,
    };

    pub fn init(cache: *FrameCache, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.stacks_max > 0);
        assert(options.frames_max >= cpu_wire.frames_max);

        cache.* = .{
            .epochs = undefined,
            .current = 0,
            .records_malformed = 0,
            .records_overflow = 0,
        };
        try cache.epochs[0].init(gpa, options);
        errdefer cache.epochs[0].deinit(gpa);
        try cache.epochs[1].init(gpa, options);
    }

    pub fn deinit(cache: *FrameCache, gpa: std.mem.Allocator) void {
        cache.epochs[0].deinit(gpa);
        cache.epochs[1].deinit(gpa);
        cache.* = undefined;
    }

    /// Forgets the older epoch, and sends new records into it from now on. Every Stack and
    /// frame slice handed out from that epoch is invalid after this.
    pub fn epoch_advance(cache: *FrameCache) void {
        cache.current +%= 1;
        cache.epochs[cache.current].clear();
    }

    /// Stores one ring record. Records come from the kernel: a bad one is counted, never trusted.
    pub fn record_add(cache: *FrameCache, bytes: []const u8) void {
        if (bytes.len < header_size) {
            cache.records_malformed += 1;
            return;
        }
        // bytesToValue copies through an align(1) pointer: the record's alignment does not matter.
        const header = std.mem.bytesToValue(RecordHeader, bytes[0..header_size]);
        const frame_bytes = bytes[header_size..];
        if (!record_valid(header, frame_bytes.len)) {
            cache.records_malformed += 1;
            return;
        }

        const id = StackId{ .hash = header.stack_hash, .tgid = header.tgid };
        // Several CPUs can send the same new stack at once; the first copy is enough.
        if (cache.epochs[cache.current].find(id) != null) return;
        if (!cache.epochs[cache.current].add(id, header, frame_bytes)) cache.records_overflow += 1;
    }

    /// The stack's frames: from this epoch, else from the previous one.
    pub fn find(cache: *const FrameCache, id: StackId) ?*const Stack {
        if (cache.epochs[cache.current].find(id)) |stack| return stack;
        return cache.epochs[cache.current +% 1].find(id);
    }
};

const Epoch = struct {
    /// StackId -> index into `stacks`. Capacity is reserved at init, so it never grows.
    index: std.AutoHashMapUnmanaged(StackId, u32),
    stacks: []Stack,
    stacks_count: u32,
    frames: []u64,
    frames_count: u32,

    fn init(epoch: *Epoch, gpa: std.mem.Allocator, options: FrameCache.Options) !void {
        epoch.* = .{
            .index = .empty,
            .stacks = &.{},
            .stacks_count = 0,
            .frames = &.{},
            .frames_count = 0,
        };
        try epoch.index.ensureTotalCapacity(gpa, options.stacks_max);
        errdefer epoch.index.deinit(gpa);
        epoch.stacks = try gpa.alloc(Stack, options.stacks_max);
        errdefer gpa.free(epoch.stacks);
        epoch.frames = try gpa.alloc(u64, options.frames_max);
    }

    fn deinit(epoch: *Epoch, gpa: std.mem.Allocator) void {
        gpa.free(epoch.frames);
        gpa.free(epoch.stacks);
        epoch.index.deinit(gpa);
        epoch.* = undefined;
    }

    fn clear(epoch: *Epoch) void {
        assert(epoch.index.count() == epoch.stacks_count);
        epoch.index.clearRetainingCapacity();
        epoch.stacks_count = 0;
        epoch.frames_count = 0;
    }

    fn find(epoch: *const Epoch, id: StackId) ?*const Stack {
        const stack_index = epoch.index.get(id) orelse return null;
        assert(stack_index < epoch.stacks_count);
        return &epoch.stacks[stack_index];
    }

    /// False when the epoch has no room for the stack.
    fn add(epoch: *Epoch, id: StackId, header: RecordHeader, frame_bytes: []const u8) bool {
        assert(epoch.find(id) == null);
        const count = frame_count(header);
        // Pair assertion: record_valid checked the size, check it again where it is used.
        assert(frame_bytes.len == count * @sizeOf(u64));

        if (epoch.stacks_count == epoch.stacks.len) return false;
        if (count > epoch.frames.len - epoch.frames_count) return false;

        const frames = epoch.frames[epoch.frames_count..][0..count];
        // Frames are native-endian u64s written by the kernel, so a byte copy is exact.
        @memcpy(std.mem.sliceAsBytes(frames), frame_bytes);
        epoch.stacks[epoch.stacks_count] = .{ .header = header, .frames = frames };
        epoch.index.putAssumeCapacityNoClobber(id, epoch.stacks_count);
        epoch.stacks_count += 1;
        epoch.frames_count += count;

        assert(epoch.index.count() == epoch.stacks_count);
        assert(epoch.frames_count <= epoch.frames.len);
        return true;
    }
};

fn frame_count(header: RecordHeader) u32 {
    return @as(u32, header.user_frame_count) + header.kernel_frame_count;
}

/// Whether the header describes a record the kernel program can write, `frame_bytes_size`
/// bytes of frames included.
fn record_valid(header: RecordHeader, frame_bytes_size: usize) bool {
    if (header.user_frame_count > cpu_wire.user_frames_max) return false;
    if (header.kernel_frame_count > cpu_wire.kernel_frames_max) return false;
    // Only the reasons the program writes: the window turns the byte into a StopReason.
    const stop = std.enums.fromInt(cpu_wire.StopReason, header.stop_reason) orelse return false;
    if (stop == .none) return false;
    if (header.flags & ~cpu_wire.record_flags_known != 0) return false;
    // Kernel frames exist only for a sample taken in kernel mode.
    if (header.kernel_frame_count > 0) {
        if (header.flags & cpu_wire.record_flag_kernel_mode == 0) return false;
    }
    return frame_bytes_size == @as(usize, frame_count(header)) * @sizeOf(u64);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

const options_testing = FrameCache.Options{ .stacks_max = 4, .frames_max = 1024 };

fn header_for_test(hash: u64, user: u8, kernel: u8) RecordHeader {
    return .{
        .stack_hash = hash,
        .tgid = 7,
        .user_frame_count = user,
        .kernel_frame_count = kernel,
        .stop_reason = @intFromEnum(cpu_wire.StopReason.end),
        .flags = if (kernel > 0) cpu_wire.record_flag_kernel_mode else 0,
    };
}

/// The header and the frames, as the kernel program writes them.
fn record_encode(buffer: []u8, header: RecordHeader, frames: []const u64) []u8 {
    @memcpy(buffer[0..header_size], std.mem.asBytes(&header));
    const size = frames.len * @sizeOf(u64);
    @memcpy(buffer[header_size..][0..size], std.mem.sliceAsBytes(frames));
    return buffer[0 .. header_size + size];
}

fn id_of(hash: u64) StackId {
    return .{ .hash = hash, .tgid = 7 };
}

test "a valid record is unpacked: header, user frames, kernel frames" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, options_testing);
    defer cache.deinit(testing.allocator);
    var buffer: [1300]u8 = undefined;

    const frames = [_]u64{ 0x10, 0x20, 0x30, 0xffff800000000001 };
    cache.record_add(record_encode(&buffer, header_for_test(0xabc, 3, 1), &frames));

    const stack = cache.find(id_of(0xabc)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 7), stack.header.tgid);
    try testing.expectEqualSlices(u64, frames[0..3], stack.user());
    try testing.expectEqualSlices(u64, frames[3..4], stack.kernel());
    try testing.expect(cache.find(.{ .hash = 0xabc, .tgid = 8 }) == null); // Another process.
}

test "the largest record fits, and a record that is not 8-byte aligned decodes the same" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, options_testing);
    defer cache.deinit(testing.allocator);
    var buffer: [1400]u8 align(8) = undefined;

    var frames: [cpu_wire.frames_max]u64 = undefined;
    for (&frames, 0..) |*frame, index| frame.* = 0x1000 + index;
    const header = header_for_test(1, cpu_wire.user_frames_max, cpu_wire.kernel_frames_max);
    // One byte in: the header and the frames sit at odd addresses.
    cache.record_add(record_encode(buffer[1..], header, &frames));

    const stack = cache.find(id_of(1)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u64, &frames, stack.frames);
    try testing.expectEqual(@as(u64, 0), cache.records_malformed);
}

test "records the kernel cannot write are counted as malformed and not stored" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, options_testing);
    defer cache.deinit(testing.allocator);
    var buffer: [1400]u8 = undefined;

    cache.record_add(buffer[0..0]);
    cache.record_add(buffer[0 .. header_size - 1]);

    const frames = [_]u64{ 1, 2, 3 };
    const valid = record_encode(&buffer, header_for_test(1, 3, 0), &frames);
    cache.record_add(valid[0 .. valid.len - 8]); // One frame short.

    var stop_unknown = header_for_test(2, 1, 0);
    stop_unknown.stop_reason = cpu_wire.stop_reason_count;
    cache.record_add(record_encode(&buffer, stop_unknown, frames[0..1]));

    var stop_none = header_for_test(3, 1, 0);
    stop_none.stop_reason = @intFromEnum(cpu_wire.StopReason.none);
    cache.record_add(record_encode(&buffer, stop_none, frames[0..1]));

    var flags_unknown = header_for_test(4, 1, 0);
    flags_unknown.flags = 1 << 7;
    cache.record_add(record_encode(&buffer, flags_unknown, frames[0..1]));

    var kernel_in_user_mode = header_for_test(5, 0, 1);
    kernel_in_user_mode.flags = 0;
    cache.record_add(record_encode(&buffer, kernel_in_user_mode, frames[0..1]));

    try testing.expectEqual(@as(u64, 7), cache.records_malformed);
    for ([_]u64{ 1, 2, 3, 4, 5 }) |hash| try testing.expect(cache.find(id_of(hash)) == null);
}

test "a stack outlives one epoch advance, and is forgotten at the second" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, options_testing);
    defer cache.deinit(testing.allocator);
    var buffer: [64]u8 = undefined;

    cache.record_add(record_encode(&buffer, header_for_test(1, 1, 0), &.{0x11}));
    cache.epoch_advance();
    try testing.expectEqual(@as(u64, 0x11), cache.find(id_of(1)).?.user()[0]);

    // The same stack again in the new epoch: found there, with the new copy's frames.
    cache.record_add(record_encode(&buffer, header_for_test(2, 1, 0), &.{0x22}));
    cache.epoch_advance();
    try testing.expect(cache.find(id_of(1)) == null);
    try testing.expectEqual(@as(u64, 0x22), cache.find(id_of(2)).?.user()[0]);
    cache.epoch_advance();
    try testing.expect(cache.find(id_of(2)) == null);
}

test "a full epoch counts overflow, keeps what it has, and has room again after it is cleared" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, .{ .stacks_max = 2, .frames_max = cpu_wire.frames_max });
    defer cache.deinit(testing.allocator);
    var buffer: [64]u8 = undefined;

    for ([_]u64{ 1, 2, 3 }) |hash| {
        cache.record_add(record_encode(&buffer, header_for_test(hash, 1, 0), &.{hash * 0x11}));
    }
    // The same stack twice is stored once, and is not an overflow.
    cache.record_add(record_encode(&buffer, header_for_test(1, 1, 0), &.{0x11}));
    try testing.expectEqual(@as(u64, 1), cache.records_overflow);
    try testing.expectEqual(@as(u64, 0x11), cache.find(id_of(1)).?.user()[0]);
    try testing.expectEqual(@as(u64, 0x22), cache.find(id_of(2)).?.user()[0]);
    try testing.expect(cache.find(id_of(3)) == null);

    cache.epoch_advance();
    cache.epoch_advance();
    cache.record_add(record_encode(&buffer, header_for_test(3, 1, 0), &.{0x33}));
    try testing.expectEqual(@as(u64, 0x33), cache.find(id_of(3)).?.user()[0]);
}

test "random records: every one is stored, a duplicate, malformed or an overflow" {
    var cache: FrameCache = undefined;
    try cache.init(testing.allocator, .{ .stacks_max = 64, .frames_max = 64 * 32 });
    defer cache.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buffer: [1400]u8 = undefined;

    var valid_sent: u64 = 0;
    var round: u32 = 0;
    while (round < 2000) : (round += 1) {
        if (round % 2 == 0) {
            // Garbage of any size: it must be refused, never stored.
            const size = random.intRangeAtMost(usize, 0, buffer.len);
            random.bytes(buffer[0..size]);
            cache.record_add(buffer[0..size]);
        } else {
            const user = random.intRangeAtMost(u8, 0, cpu_wire.user_frames_max);
            const kernel = random.intRangeAtMost(u8, 0, cpu_wire.kernel_frames_max);
            var frames: [cpu_wire.frames_max]u64 = undefined;
            random.bytes(std.mem.sliceAsBytes(&frames));
            const header = header_for_test(random.int(u64), user, kernel);
            const malformed_before = cache.records_malformed;
            const overflow_before = cache.records_overflow;
            const frame_count_sent = @as(usize, user) + kernel;
            cache.record_add(record_encode(&buffer, header, frames[0..frame_count_sent]));
            // A valid record is never malformed: it is stored, or it overflows.
            try testing.expectEqual(malformed_before, cache.records_malformed);
            if (cache.records_overflow == overflow_before) {
                const stack = cache.find(.{ .hash = header.stack_hash, .tgid = 7 }) orelse
                    return error.TestUnexpectedResult;
                try testing.expectEqual(@as(usize, user), stack.user().len);
                try testing.expectEqual(@as(usize, kernel), stack.kernel().len);
            }
            valid_sent += 1;
        }
        if (round % 128 == 0) cache.epoch_advance();
    }
    try testing.expect(valid_sent > 0);
    try testing.expect(cache.records_malformed > 0); // Garbage was refused.
}
