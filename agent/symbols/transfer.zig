//! One binary on its way, at most `chunks_max` chunks per `pump`, so the loop keeps draining.
//! The sink gets what a network stream would: begin, chunks, end.

const std = @import("std");
const assert = std.debug.assert;
const binary_file = @import("binary.zig");

const Binary = binary_file.Binary;
const Section = binary_file.Section;

const sections = std.enums.values(Section);

pub const Transfer = struct {
    binary: Binary,
    stage: enum { begin, sections, end, done },
    /// The section being sent, as an index into the sections, and the offset in it.
    section_index: usize,
    offset: u64,

    /// Takes the binary: `deinit` closes it.
    pub fn init(binary: Binary) Transfer {
        return .{ .binary = binary, .stage = .begin, .section_index = 0, .offset = 0 };
    }

    /// Whether the sink has had `binary_begin`: a transfer dropped after it must be aborted.
    pub fn begun(transfer: *const Transfer) bool {
        return transfer.stage != .begin;
    }

    pub fn deinit(transfer: *Transfer) void {
        transfer.binary.deinit();
        transfer.* = undefined;
    }

    /// Sends the header first, then up to `chunks_max` chunks of at most `buffer.len` bytes
    /// each, and `binary_end` after the last one. Returns true once the end has been sent.
    ///
    /// `sink` is a pointer to a struct with `binary_begin(header)`, `binary_chunk(chunk)` and
    /// `binary_end()`. An error from the sink or from the file stops the transfer: the caller
    /// drops it, and tells the sink with `binary_abort()` if it had begun.
    pub fn pump(transfer: *Transfer, sink: anytype, buffer: []u8, chunks_max: u32) !bool {
        assert(transfer.stage != .done);
        assert(buffer.len > 0);
        assert(chunks_max > 0);

        if (transfer.stage == .begin) {
            try sink.binary_begin(&transfer.binary.header);
            transfer.stage = .sections;
        }

        var sent: u32 = 0;
        while (transfer.stage == .sections) {
            if (transfer.section_index == sections.len) {
                transfer.stage = .end;
                break;
            }
            const section = sections[transfer.section_index];
            if (transfer.offset >= transfer.binary.header.sizes.get(section)) {
                transfer.section_index += 1;
                transfer.offset = 0;
                continue;
            }
            if (sent == chunks_max) return false;

            const bytes = try transfer.binary.read(section, transfer.offset, buffer);
            assert(bytes.len > 0);
            try sink.binary_chunk(&.{
                .section = section,
                .offset = transfer.offset,
                .bytes = bytes,
            });
            transfer.offset += bytes.len;
            sent += 1;
        }

        assert(transfer.stage == .end);
        try sink.binary_end();
        transfer.stage = .done;
        return true;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const Region = @import("../target/regions.zig").Region;
const build_id = @import("../target/build_id.zig");
const vdso = @import("../target/vdso.zig");
const process = @import("../os/process.zig");

/// A receiver that puts the sections back together, and checks the order of the calls.
const Recorder = struct {
    arena: std.mem.Allocator,
    begins: u32 = 0,
    chunks: u32 = 0,
    ends: u32 = 0,
    sections: std.EnumArray(Section, std.ArrayList(u8)) = .initFill(.empty),

    pub fn binary_begin(recorder: *Recorder, header: *const binary_file.Header) !void {
        _ = header;
        try testing.expectEqual(@as(u32, 0), recorder.begins);
        recorder.begins += 1;
    }

    pub fn binary_chunk(recorder: *Recorder, chunk: *const binary_file.Chunk) !void {
        try testing.expectEqual(@as(u32, 1), recorder.begins);
        try testing.expectEqual(@as(u32, 0), recorder.ends);
        const list = recorder.sections.getPtr(chunk.section);
        // In order, with no gap and no overlap.
        try testing.expectEqual(@as(u64, list.items.len), chunk.offset);
        try list.appendSlice(recorder.arena, chunk.bytes);
        recorder.chunks += 1;
    }

    pub fn binary_end(recorder: *Recorder) !void {
        try testing.expectEqual(@as(u32, 0), recorder.ends);
        recorder.ends += 1;
    }
};

test "a transfer sends the whole binary a few chunks per round, then ends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    const id = image.build_id orelse return error.SkipZigTest;
    const region = Region{
        .start = 0x7000,
        .end = 0x7000 + image.bytes.len,
        .offset = 0,
        .inode = 0,
        .path = vdso.path,
        .build_id = id,
    };
    var prefix: [build_id.prefix_size]u8 = undefined;
    const binary = try binary_file.open(
        arena.allocator(),
        process.current_pid(),
        &region,
        &prefix,
        &image,
    );
    const sizes = binary.header.sizes;

    var transfer = Transfer.init(binary);
    defer transfer.deinit();
    var recorder = Recorder{ .arena = arena.allocator() };

    // Small chunks, three per round: it takes several rounds, each bounded.
    var buffer: [16]u8 = undefined;
    var rounds: u32 = 0;
    var chunks_before: u32 = 0;
    while (!try transfer.pump(&recorder, &buffer, 3)) {
        rounds += 1;
        try testing.expect(recorder.chunks - chunks_before <= 3);
        chunks_before = recorder.chunks;
        try testing.expect(rounds < 10_000);
    }

    try testing.expect(rounds > 1);
    try testing.expectEqual(@as(u32, 1), recorder.begins);
    try testing.expectEqual(@as(u32, 1), recorder.ends);
    // Everything arrived: each section has the size the header announced.
    for (std.enums.values(Section)) |section| {
        try testing.expectEqual(sizes.get(section), recorder.sections.get(section).items.len);
    }
    const dynstr = recorder.sections.get(.dynstr).items;
    try testing.expect(std.mem.indexOf(u8, dynstr, "__vdso_clock_gettime") != null);
}
