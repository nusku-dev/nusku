//! One binary on its way.

const std = @import("std");
const assert = std.debug.assert;
const target = @import("../target/target.zig");
const binary_file = @import("binary.zig");

const Binary = binary_file.Binary;
const Section = binary_file.Section;

const sections = std.enums.values(Section);

pub const Part = union(enum) {
    begin: *const binary_file.Header,
    chunk: binary_file.Chunk,
    end,
};

pub const Transfer = struct {
    binary: Binary,
    stage: enum { begin, sections, done },
    section_index: usize,
    offset: u64,

    pub fn init(binary: Binary) Transfer {
        return .{ .binary = binary, .stage = .begin, .section_index = 0, .offset = 0 };
    }

    pub fn deinit(transfer: *Transfer) void {
        transfer.binary.deinit();
        transfer.* = undefined;
    }

    pub fn begun(transfer: *const Transfer) bool {
        return transfer.stage != .begin;
    }

    pub fn done(transfer: *const Transfer) bool {
        return transfer.stage == .done;
    }

    pub fn step(transfer: *Transfer, buffer: []u8) !Part {
        assert(transfer.stage != .done);
        assert(buffer.len > 0);
        if (transfer.stage == .begin) {
            transfer.stage = .sections;
            return .{ .begin = &transfer.binary.header };
        }
        while (transfer.section_index < sections.len) {
            const section = sections[transfer.section_index];
            if (transfer.offset >= transfer.binary.header.sizes.get(section)) {
                transfer.section_index += 1;
                transfer.offset = 0;
                continue;
            }
            const bytes = try transfer.binary.read(section, transfer.offset, buffer);
            assert(bytes.len > 0);
            const offset = transfer.offset;
            transfer.offset += bytes.len;
            return .{ .chunk = .{ .section = section, .offset = offset, .bytes = bytes } };
        }
        transfer.stage = .done;
        return .end;
    }
};

const testing = std.testing;
const os = @import("../os/os.zig");
const Region = target.Region;
const process = @import("../os/os.zig").process;

test "a transfer gives the header, every byte in order, then the end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const image = own.vdso_image() orelse return error.SkipZigTest;
    const id = image.build_id orelse return error.SkipZigTest;
    const region = Region{
        .start = 0x7000,
        .end = 0x7000 + image.bytes.len,
        .offset = 0,
        .inode = 0,
        .path = target.vdso_path,
        .build_id = id,
    };
    var prefix: [target.build_id_prefix_size]u8 = undefined;
    const pid = process.current_pid();
    const binary = try binary_file.open(arena.allocator(), pid, &region, &prefix, image);
    const sizes = binary.header.sizes;

    var transfer = Transfer.init(binary);
    defer transfer.deinit();
    var buffer: [16]u8 = undefined;
    try testing.expect(!transfer.begun());
    try testing.expect((try transfer.step(&buffer)) == .begin);
    try testing.expect(transfer.begun());

    var received = std.EnumArray(Section, std.ArrayList(u8)).initFill(.empty);
    var chunks: u32 = 0;
    while (!transfer.done()) {
        switch (try transfer.step(&buffer)) {
            .begin => return error.TestUnexpectedResult,
            .chunk => |chunk| {
                const list = received.getPtr(chunk.section);
                try testing.expectEqual(@as(u64, list.items.len), chunk.offset);
                try list.appendSlice(arena.allocator(), chunk.bytes);
                chunks += 1;
            },
            .end => try testing.expect(transfer.done()),
        }
    }
    try testing.expect(chunks > 1);
    for (std.enums.values(Section)) |section| {
        try testing.expectEqual(sizes.get(section), received.get(section).items.len);
    }
    const dynstr = received.get(.dynstr).items;
    try testing.expect(std.mem.indexOf(u8, dynstr, "__vdso_clock_gettime") != null);
}
