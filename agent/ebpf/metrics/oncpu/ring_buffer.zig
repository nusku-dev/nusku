const std = @import("std");
const ring_buf = @import("../../libc/ring_buf.zig");
const stack_record = @import("../../kernel/shared/stack_record.zig");

const assert = std.debug.assert;

const Error = ring_buf.Error;
const RecordCallback = ring_buf.RecordCallback;
const cRingBuff = ring_buf.cRingBuf;

const header_size = @sizeOf(stack_record.RecordHeader);

const stack_capacity = 1024;

pub const RingBuffer = struct {
    gpa: std.mem.Allocator,
    sink: *Sink,
    stacks: []Stack,
    c_ring_buf: cRingBuff,

    pub fn init(gpa: std.mem.Allocator, map_fd: c_int) !RingBuffer {
        const sink = try gpa.create(Sink);
        const stacks = try gpa.alloc(Stack, stack_capacity);
        sink.init(stacks);

        assert(sink.stacks.len == stack_capacity);
        assert(sink.overflow == 0 and sink.malformed == 0 and sink.count == 0);

        const c_ring_buf = try cRingBuff.init(map_fd, record_callback, sink);

        return .{
            .gpa = gpa,
            .sink = sink,
            .stacks = stacks,
            .c_ring_buf = c_ring_buf,
        };
    }
    /// Reads everything that is in the ring now. Returns how many records it read.
    pub fn consume(self: RingBuffer) !u32 {
        return try self.c_ring_buf.consume();
    }

    fn record_callback(context: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int {
        const sink: *Sink = @ptrCast(@alignCast(context.?));
        assert(sink.count <= sink.stacks.len);

        const base: [*]const u8 = @ptrCast(data.?);
        const bytes = base[0..size];

        if (bytes.len < header_size) {
            sink.malformed += 1;
            return 0;
        }

        // bytesToValue copies through an align(1) pointer, so record alignment doesn't matter.
        const header = std.mem.bytesToValue(stack_record.RecordHeader, bytes[0..header_size]);
        const frame_bytes = bytes[header_size..];

        if (record_valid(header, frame_bytes.len)) {
            if (sink.count < sink.stacks.len) {
                record_unpack(&sink.stacks[sink.count], header, frame_bytes);
                sink.count += 1;
            } else {
                sink.overflow += 1;
            }
        } else {
            sink.malformed += 1;
        }

        assert(sink.count <= sink.stacks.len);
        // Never negative: that would stop libbpf from draining the ring.
        return 0;
    }

    /// Records come from the kernel, so a bad one is counted, not a crash.
    fn record_valid(header: stack_record.RecordHeader, frame_bytes_len: usize) bool {
        if (header.user_frame_count > stack_record.MAX_STACK_FRAMES) return false;
        if (header.kernel_frame_count > stack_record.MAX_KERNEL_STACK_FRAMES) return false;
        if (header.stop_reason >= stack_record.STOP_REASON_COUNT) return false;
        if (header.flags & ~stack_record.flags_known != 0) return false;

        const frame_count = @as(usize, header.user_frame_count) + header.kernel_frame_count;
        return frame_bytes_len == frame_count * @sizeOf(u64);
    }

    fn record_unpack(target: *Stack, header: stack_record.RecordHeader, frame_bytes: []const u8) void {
        const frame_count = @as(usize, header.user_frame_count) + header.kernel_frame_count;

        // Pair assertions: record_valid checked these, check again right where we write.
        assert(frame_count <= target.frames.len);
        assert(frame_bytes.len == frame_count * @sizeOf(u64));

        target.header = header;
        // Frames are native-endian u64s written by BPF, so a byte copy is exact.
        @memcpy(std.mem.sliceAsBytes(target.frames[0..frame_count]), frame_bytes);
        // Slots are reused: clear what the previous record left behind.
        @memset(target.frames[frame_count..], 0);
    }

    pub fn deinit(self: *RingBuffer) void {
        self.gpa.free(self.stacks);
        self.gpa.destroy(self.sink);
        self.c_ring_buf.deinit();
        self.* = undefined;
    }
};

const frame_count_max = stack_record.MAX_STACK_FRAMES + stack_record.MAX_KERNEL_STACK_FRAMES;

/// A record of the ring, unpacked.
const Stack = struct {
    header: stack_record.RecordHeader,
    frames: [frame_count_max]u64,

    pub fn user(stack: *const Stack) []const u64 {
        assert(stack.header.user_frame_count <= stack_record.MAX_STACK_FRAMES);
        return stack.frames[0..stack.header.user_frame_count];
    }

    pub fn kernel(stack: *const Stack) []const u64 {
        assert(stack.header.kernel_frame_count <= stack_record.MAX_KERNEL_STACK_FRAMES);
        const start = stack.header.user_frame_count;
        return stack.frames[start..][0..stack.header.kernel_frame_count];
    }
};

const Sink = struct {
    stacks: []Stack,
    count: u32,
    malformed: u64,
    overflow: u64,

    pub fn init(sink: *Sink, stacks: []Stack) void {
        sink.* = Sink{
            .stacks = stacks,
            .count = 0,
            .malformed = 0,
            .overflow = 0,
        };
    }

    pub fn deinit(self: *Sink) void {
        self.* = undefined;
    }

    /// The stacks read since the last reset.
    pub fn filled(sink: *const Sink) []const Stack {
        assert(sink.count <= sink.stacks.len);
        return sink.stacks[0..sink.count];
    }

    pub fn reset(sink: *Sink) void {
        assert(sink.count <= sink.stacks.len);
        sink.count = 0;
    }
};

test "record_valid rejects bad headers" {
    const valid: stack_record.RecordHeader = .{
        .stack_hash = 1,
        .tgid = 100,
        .user_frame_count = 2,
        .kernel_frame_count = 1,
        .stop_reason = 0,
        .flags = 0,
    };
    try std.testing.expect(RingBuffer.record_valid(valid, 3 * 8));
    // Positive space as data becomes invalid: one frame short, one frame long.
    try std.testing.expect(!RingBuffer.record_valid(valid, 2 * 8));
    try std.testing.expect(!RingBuffer.record_valid(valid, 4 * 8));

    var bad_stop = valid;
    bad_stop.stop_reason = stack_record.STOP_REASON_COUNT;
    try std.testing.expect(!RingBuffer.record_valid(bad_stop, 3 * 8));

    var bad_flags = valid;
    bad_flags.flags = 1 << 7;
    try std.testing.expect(!RingBuffer.record_valid(bad_flags, 3 * 8));

    var too_many = valid;
    too_many.user_frame_count = stack_record.MAX_STACK_FRAMES + 1;
    try std.testing.expect(!RingBuffer.record_valid(too_many, 3 * 8));
}

const RecordHeader = stack_record.RecordHeader;

fn hdr(user: u8, kernel: u8) RecordHeader {
    return .{ .stack_hash = 0xabc, .tgid = 7, .user_frame_count = user, .kernel_frame_count = kernel, .stop_reason = 1, .flags = 0 };
}

/// Header bytes followed by the frames, as the kernel program writes them.
fn encode(buf: []u8, header: RecordHeader, frames: []const u64) []u8 {
    @memcpy(buf[0..header_size], std.mem.asBytes(&header));
    const n = frames.len * @sizeOf(u64);
    @memcpy(buf[header_size..][0..n], std.mem.sliceAsBytes(frames));
    return buf[0 .. header_size + n];
}

/// What libbpf does: call the callback, which must always return 0.
fn feed(sink: *Sink, bytes: []const u8) !void {
    const rc = RingBuffer.record_callback(sink, @constCast(bytes.ptr), bytes.len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
}

test "a valid record is decoded: header, user frames, kernel frames" {
    var stacks: [4]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;

    const frames = [_]u64{ 0x10, 0x20, 0x30, 0xffff800000000001 };
    try feed(&sink, encode(&buf, hdr(3, 1), &frames));

    try std.testing.expectEqual(@as(u32, 1), sink.count);
    const s = &sink.filled()[0];
    try std.testing.expectEqual(@as(u64, 0xabc), s.header.stack_hash);
    try std.testing.expectEqual(@as(u32, 7), s.header.tgid);
    try std.testing.expectEqualSlices(u64, frames[0..3], s.user());
    try std.testing.expectEqualSlices(u64, frames[3..4], s.kernel());
}

test "a record with no frames at all is accepted" {
    var stacks: [1]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [64]u8 = undefined;
    try feed(&sink, encode(&buf, hdr(0, 0), &.{}));
    try std.testing.expectEqual(@as(u32, 1), sink.count);
    try std.testing.expectEqual(@as(usize, 0), sink.filled()[0].user().len);
    try std.testing.expectEqual(@as(usize, 0), sink.filled()[0].kernel().len);
}

test "the largest possible record fits" {
    var stacks: [1]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;
    var frames: [stack_record.MAX_STACK_FRAMES + stack_record.MAX_KERNEL_STACK_FRAMES]u64 = undefined;
    for (&frames, 0..) |*f, i| f.* = 0x1000 + i;
    try feed(&sink, encode(&buf, hdr(stack_record.MAX_STACK_FRAMES, stack_record.MAX_KERNEL_STACK_FRAMES), &frames));
    try std.testing.expectEqual(@as(u32, 1), sink.count);
    const s = &sink.filled()[0];
    try std.testing.expectEqual(@as(u64, 0x1000), s.user()[0]);
    try std.testing.expectEqual(@as(u64, 0x1000 + frames.len - 1), s.kernel()[s.kernel().len - 1]);
}

test "data that is not 8-byte aligned decodes the same" {
    var stacks: [1]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 align(8) = undefined;
    const frames = [_]u64{ 0xdeadbeef, 0xcafe };
    // Start one byte in: the record's header and frames sit at odd addresses.
    try feed(&sink, encode(buf[1..], hdr(2, 0), &frames));
    try std.testing.expectEqualSlices(u64, &frames, sink.filled()[0].user());
}

test "records that are too short or the wrong size are counted as malformed" {
    var stacks: [4]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;

    try feed(&sink, buf[0..0]); // empty
    try feed(&sink, buf[0 .. header_size - 1]); // one byte short of a header

    const frames = [_]u64{ 1, 2, 3 };
    const ok = encode(&buf, hdr(3, 0), &frames);
    try feed(&sink, ok[0 .. ok.len - 8]); // one frame missing
    var long: [1300]u8 = undefined;
    const too_long = encode(&long, hdr(2, 0), &frames); // header says 2, bytes hold 3
    try feed(&sink, too_long);

    try std.testing.expectEqual(@as(u32, 0), sink.count);
    try std.testing.expectEqual(@as(u64, 4), sink.malformed);
    try std.testing.expectEqual(@as(u64, 0), sink.overflow);
}

test "unknown stop reasons, unknown flags and too many frames are malformed" {
    var stacks: [4]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;

    var h = hdr(1, 0);
    h.stop_reason = stack_record.STOP_REASON_COUNT;
    try feed(&sink, encode(&buf, h, &.{1}));

    h = hdr(1, 0);
    h.flags = 1 << 7;
    try feed(&sink, encode(&buf, h, &.{1}));

    h = hdr(stack_record.MAX_STACK_FRAMES + 1, 0);
    var frames: [stack_record.MAX_STACK_FRAMES + 1]u64 = @splat(0);
    try feed(&sink, encode(&buf, h, &frames));

    try std.testing.expectEqual(@as(u32, 0), sink.count);
    try std.testing.expectEqual(@as(u64, 3), sink.malformed);
}

test "when the sink is full the record is counted as overflow and nothing is overwritten" {
    var stacks: [2]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;

    for ([_]u64{ 0x11, 0x22, 0x33 }) |marker| {
        try feed(&sink, encode(&buf, hdr(1, 0), &.{marker}));
    }
    try std.testing.expectEqual(@as(u32, 2), sink.count);
    try std.testing.expectEqual(@as(u64, 1), sink.overflow);
    try std.testing.expectEqual(@as(u64, 0x11), sink.filled()[0].user()[0]);
    try std.testing.expectEqual(@as(u64, 0x22), sink.filled()[1].user()[0]);
}

test "reset makes room again and a reused slot keeps nothing from the old record" {
    var stacks: [1]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);
    var buf: [1300]u8 = undefined;

    try feed(&sink, encode(&buf, hdr(5, 0), &.{ 1, 2, 3, 4, 5 }));
    sink.reset();
    try std.testing.expectEqual(@as(u32, 0), sink.count);

    try feed(&sink, encode(&buf, hdr(2, 0), &.{ 9, 8 }));
    const s = &sink.filled()[0];
    try std.testing.expectEqualSlices(u64, &.{ 9, 8 }, s.user());
    for (s.frames[2..]) |f| try std.testing.expectEqual(@as(u64, 0), f);
}

test "every record is stored, malformed or overflow, and the callback never crashes" {
    var stacks: [8]Stack = undefined;
    var sink: Sink = undefined;
    sink.init(&stacks);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buf: [1300]u8 = undefined;
    const total = 2000;

    for (0..total) |i| {
        if (i % 2 == 0) {
            // garbage of any size
            const len = random.intRangeAtMost(usize, 0, buf.len);
            random.bytes(buf[0..len]);
            try feed(&sink, buf[0..len]);
        } else {
            // a well-formed record with random counts and frames
            const user = random.intRangeAtMost(u8, 0, stack_record.MAX_STACK_FRAMES);
            const kernel = random.intRangeAtMost(u8, 0, stack_record.MAX_KERNEL_STACK_FRAMES);
            var frames: [stack_record.MAX_STACK_FRAMES + stack_record.MAX_KERNEL_STACK_FRAMES]u64 = undefined;
            random.bytes(std.mem.sliceAsBytes(&frames));
            try feed(&sink, encode(&buf, hdr(user, kernel), frames[0 .. @as(usize, user) + kernel]));
        }
        if (sink.count == sink.stacks.len) sink.reset(); // keep room, count what was stored
    }
    // Count stored ones before each reset, so track them with a counter in your version:
    // stored + malformed + overflow must equal `total`.
}
