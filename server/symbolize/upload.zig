//! One binary arriving from one agent: `begin`, `chunk` ..., `end`. The header says how big
//! each section will be, so everything is allocated once, up front, within a budget. At `end`
//! the buffers are handed over as a `Received`, for the server to build the symbol table from.
//! Whatever arrives is untrusted: anything that does not fit what the header announced ends the
//! upload.

const std = @import("std");
const agent = @import("agent");
const elf = @import("shared").elf;
const Received = @import("builder.zig").Received;

const assert = std.debug.assert;
const Header = agent.binary.Header;
const Chunk = agent.binary.Chunk;
const Section = agent.binary.Section;
const sections = std.enums.values(Section);

pub const Error = error{
    /// A call that does not fit the state: a chunk with no begin, a begin in the middle of one.
    OutOfOrder,
    /// Data that does not fit what the header announced.
    Malformed,
    /// The sections together are bigger than the budget.
    TooLarge,
    OutOfMemory,
};

const id_bytes_max = @import("../store/id_set.zig").id_bytes_max;
/// The agent sends at most 16 executable segments; more than this is not a real file.
const segments_max = 64;

/// What the sections of `header` take together: what an upload of it allocates.
pub fn bytes_of(header: *const Header) error{TooLarge}!u64 {
    var total: u64 = 0;
    for (sections) |section| {
        total = std.math.add(u64, total, header.sizes.get(section)) catch return error.TooLarge;
    }
    return total;
}

pub const Upload = struct {
    /// What the buffers of one upload may take.
    bytes_max: u64,
    receiving: bool,
    id: []u8,
    segments: []elf.Segment,
    /// The four sections one after the other.
    data: []u8,
    starts: std.EnumArray(Section, usize),
    sizes: std.EnumArray(Section, usize),
    filled: std.EnumArray(Section, usize),

    pub fn init(bytes_max: u64) Upload {
        return .{
            .bytes_max = bytes_max,
            .receiving = false,
            .id = &.{},
            .segments = &.{},
            .data = &.{},
            .starts = .initFill(0),
            .sizes = .initFill(0),
            .filled = .initFill(0),
        };
    }

    /// Frees what an upload in progress holds.
    pub fn deinit(upload: *Upload, gpa: std.mem.Allocator) void {
        upload.abort(gpa);
        upload.* = undefined;
    }

    /// Starts a binary. A begin while another upload is in progress is an error and drops it.
    pub fn begin(upload: *Upload, gpa: std.mem.Allocator, header: *const Header) Error!void {
        if (upload.receiving) {
            upload.abort(gpa);
            return error.OutOfOrder;
        }
        if (header.build_id.len == 0 or header.build_id.len > id_bytes_max) return error.Malformed;
        if (header.segments.len > segments_max) return error.Malformed;

        const total = try bytes_of(header);
        if (total > upload.bytes_max) return error.TooLarge;

        const id = try gpa.dupe(u8, header.build_id);
        errdefer gpa.free(id);
        const segments = try gpa.dupe(elf.Segment, header.segments);
        errdefer gpa.free(segments);
        const data = try gpa.alloc(u8, @intCast(total));
        errdefer gpa.free(data);

        var starts = std.EnumArray(Section, usize).initFill(0);
        var sizes = std.EnumArray(Section, usize).initFill(0);
        var at: usize = 0;
        for (sections) |section| {
            const size: usize = @intCast(header.sizes.get(section));
            starts.set(section, at);
            sizes.set(section, size);
            at += size;
        }
        assert(at == data.len);

        upload.* = .{
            .bytes_max = upload.bytes_max,
            .receiving = true,
            .id = id,
            .segments = segments,
            .data = data,
            .starts = starts,
            .sizes = sizes,
            .filled = .initFill(0),
        };
    }

    /// The next bytes of a section. They must come in order, with no gap, and fit the size the
    /// header announced; otherwise the upload is dropped.
    pub fn chunk(upload: *Upload, gpa: std.mem.Allocator, part: *const Chunk) Error!void {
        if (!upload.receiving) return error.OutOfOrder;
        errdefer upload.abort(gpa);

        const filled = upload.filled.get(part.section);
        const size = upload.sizes.get(part.section);
        assert(filled <= size);
        if (part.bytes.len == 0) return error.Malformed;
        if (part.offset != filled) return error.Malformed;
        if (part.bytes.len > size - filled) return error.Malformed;

        const at = upload.starts.get(part.section) + filled;
        @memcpy(upload.data[at..][0..part.bytes.len], part.bytes);
        upload.filled.set(part.section, filled + part.bytes.len);
        upload.verify();
    }

    /// Checks that every section arrived whole, and hands the buffers over: the caller owns
    /// them from then on. The upload is idle after this, whatever it returns.
    pub fn end(upload: *Upload, gpa: std.mem.Allocator) Error!Received {
        if (!upload.receiving) return error.OutOfOrder;
        errdefer upload.abort(gpa);

        for (sections) |section| {
            if (upload.filled.get(section) != upload.sizes.get(section)) return error.Malformed;
        }
        const received = Received{
            .id = upload.id,
            .segments = upload.segments,
            .data = upload.data,
            .starts = upload.starts,
            .sizes = upload.sizes,
        };
        // Handed over, not freed.
        upload.receiving = false;
        upload.abort(gpa);
        return received;
    }

    /// Drops the upload in progress, if any, and frees its buffers. The upload is idle after.
    pub fn abort(upload: *Upload, gpa: std.mem.Allocator) void {
        if (upload.receiving) {
            gpa.free(upload.id);
            gpa.free(upload.segments);
            gpa.free(upload.data);
        }
        upload.receiving = false;
        upload.id = &.{};
        upload.segments = &.{};
        upload.data = &.{};
        upload.verify();
    }

    /// An idle upload holds no buffers; a receiving one never has more than it announced.
    fn verify(upload: *const Upload) void {
        if (!upload.receiving) {
            assert(upload.id.len == 0 and upload.segments.len == 0 and upload.data.len == 0);
            return;
        }
        for (sections) |section| assert(upload.filled.get(section) <= upload.sizes.get(section));
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

const segments_test = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};
const strtab_test = "\x00main\x00helper\x00";

fn symtab_test() [2 * 24]u8 {
    var out: [2 * 24]u8 = @splat(0);
    const names = [_]u32{ 1, 6 };
    const values = [_]u64{ 0x401100, 0x401200 };
    for (0..2) |i| {
        const at = i * 24;
        std.mem.writeInt(u32, out[at..][0..4], names[i], .little);
        out[at + 4] = 0x12; // Global function.
        std.mem.writeInt(u16, out[at + 6 ..][0..2], 1, .little); // Defined.
        std.mem.writeInt(u64, out[at + 8 ..][0..8], values[i], .little);
        std.mem.writeInt(u64, out[at + 16 ..][0..8], 0x10, .little);
    }
    return out;
}

fn header_test(strtab_size: u64) Header {
    var sizes = std.EnumArray(Section, u64).initFill(0);
    sizes.set(.symtab, 2 * 24);
    sizes.set(.strtab, strtab_size);
    return .{ .build_id = "id-1", .path = "/test", .segments = &segments_test, .sizes = sizes };
}

/// Sends `bytes` as chunks of `step` bytes.
fn send(upload: *Upload, section: Section, bytes: []const u8, step: usize) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const part = bytes[offset..@min(offset + step, bytes.len)];
        const chunk = Chunk{ .section = section, .offset = offset, .bytes = part };
        try upload.chunk(testing.allocator, &chunk);
        offset += part.len;
    }
}

test "a binary in small chunks becomes a table that names its functions" {
    var upload = Upload.init(1 << 20);
    defer upload.deinit(testing.allocator);

    const symtab = symtab_test();
    try upload.begin(testing.allocator, &header_test(strtab_test.len));
    try send(&upload, .symtab, &symtab, 7);
    try send(&upload, .strtab, strtab_test, 5);
    var received = try upload.end(testing.allocator);
    defer received.deinit(testing.allocator);
    try testing.expect(!upload.receiving);
    try testing.expectEqualStrings("id-1", received.id);

    var table = try received.build(testing.allocator);
    defer table.deinit(testing.allocator);
    // 0x401100 is at file offset 0x1000 + 0x100.
    try testing.expectEqualStrings("main", table.lookup(0x1105).?.name);
    try testing.expectEqualStrings("helper", table.lookup(0x1200).?.name);
}

test "chunks out of order, too long, or with no begin are refused and the upload is dropped" {
    var upload = Upload.init(1 << 20);
    defer upload.deinit(testing.allocator);
    const symtab = symtab_test();

    try testing.expectError(error.OutOfOrder, upload.chunk(testing.allocator, &.{
        .section = .symtab,
        .offset = 0,
        .bytes = &symtab,
    }));

    // A gap: the first chunk starts at 5.
    try upload.begin(testing.allocator, &header_test(strtab_test.len));
    try testing.expectError(error.Malformed, upload.chunk(testing.allocator, &.{
        .section = .symtab,
        .offset = 5,
        .bytes = symtab[5..10],
    }));
    try testing.expect(!upload.receiving);

    // More bytes than the header announced.
    try upload.begin(testing.allocator, &header_test(4));
    try testing.expectError(error.Malformed, upload.chunk(testing.allocator, &.{
        .section = .strtab,
        .offset = 0,
        .bytes = strtab_test,
    }));
    try testing.expect(!upload.receiving);

    // An empty chunk.
    try upload.begin(testing.allocator, &header_test(4));
    try testing.expectError(error.Malformed, upload.chunk(testing.allocator, &.{
        .section = .strtab,
        .offset = 0,
        .bytes = &.{},
    }));
}

test "an end before all the bytes arrived is refused, and the upload is dropped" {
    var upload = Upload.init(1 << 20);
    defer upload.deinit(testing.allocator);

    const symtab = symtab_test();
    try upload.begin(testing.allocator, &header_test(strtab_test.len));
    try send(&upload, .symtab, &symtab, 100);
    try testing.expectError(error.Malformed, upload.end(testing.allocator));
    try testing.expect(!upload.receiving);
    try testing.expectError(error.OutOfOrder, upload.end(testing.allocator));
}

test "sections bigger than the budget are refused before anything is allocated" {
    var upload = Upload.init(10);
    defer upload.deinit(testing.allocator);

    const header_big = header_test(strtab_test.len);
    try testing.expectError(error.TooLarge, upload.begin(testing.allocator, &header_big));
    try testing.expect(!upload.receiving);

    // Sizes that overflow when added are refused the same way.
    var header = header_test(0);
    header.sizes.set(.symtab, std.math.maxInt(u64));
    header.sizes.set(.strtab, 2);
    try testing.expectError(error.TooLarge, upload.begin(testing.allocator, &header));
}

test "a begin in the middle of an upload is an error, and the next begin works" {
    var upload = Upload.init(1 << 20);
    defer upload.deinit(testing.allocator);

    const header_good = header_test(strtab_test.len);
    try upload.begin(testing.allocator, &header_good);
    try testing.expectError(error.OutOfOrder, upload.begin(testing.allocator, &header_good));
    try upload.begin(testing.allocator, &header_good);
    try testing.expect(upload.receiving);

    var header = header_test(strtab_test.len);
    header.build_id = "";
    try testing.expectError(error.OutOfOrder, upload.begin(testing.allocator, &header));
    try testing.expectError(error.Malformed, upload.begin(testing.allocator, &header));
}

/// Any sequence of calls with any headers and chunks, as a broken or hostile agent could send:
/// nothing crashes, nothing leaks, and the upload is always consistent.
fn upload_fuzz(_: void, smith: *testing.Smith) !void {
    var upload = Upload.init(256);
    defer upload.deinit(testing.allocator);
    var buffer: [64]u8 = undefined;

    while (!smith.eosWeightedSimple(7, 1)) {
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => {
                var header = header_test(0);
                for (sections) |section| {
                    header.sizes.set(section, smith.valueRangeAtMost(u64, 0, 100));
                }
                upload.begin(testing.allocator, &header) catch {};
            },
            1 => {
                const part = Chunk{
                    .section = @enumFromInt(smith.valueRangeAtMost(u8, 0, sections.len - 1)),
                    .offset = smith.valueRangeAtMost(u64, 0, 120),
                    .bytes = buffer[0..smith.slice(&buffer)],
                };
                upload.chunk(testing.allocator, &part) catch {};
            },
            2 => {
                var received = upload.end(testing.allocator) catch continue;
                received.deinit(testing.allocator);
            },
            else => upload.abort(testing.allocator),
        }
        upload.verify();
    }
}

test "fuzz: any calls in any order leave the upload consistent (zig build test --fuzz)" {
    try testing.fuzz({}, upload_fuzz, .{});
}

test "the upload fuzz body on random inputs (until --fuzz works in this Zig)" {
    var prng = std.Random.DefaultPrng.init(0x6e75736b75);
    var input: [2048]u8 = undefined;
    for (0..2000) |_| {
        const length = prng.random().uintAtMost(usize, input.len);
        prng.random().bytes(input[0..length]);
        var smith: testing.Smith = .{ .in = input[0..length] };
        try upload_fuzz({}, &smith);
    }
}
