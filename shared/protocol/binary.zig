//! A binary sent for its symbols.

const std = @import("std");
const elf = @import("../elf.zig");

pub const Section = enum {
    symtab,
    strtab,
    dynsym,
    dynstr,

    pub fn name(section: Section) []const u8 {
        return switch (section) {
            .symtab => ".symtab",
            .strtab => ".strtab",
            .dynsym => ".dynsym",
            .dynstr => ".dynstr",
        };
    }
};

pub const Offer = struct {
    build_id: []const u8,
    path: []const u8,
};

pub const Header = struct {
    build_id: []const u8,
    path: []const u8,
    segments: []const Segment,
    sizes: std.EnumArray(Section, u64),

    pub const Segment = elf.Segment;

    pub fn clone(header: *const Header, arena: std.mem.Allocator) !Header {
        return .{
            .build_id = try arena.dupe(u8, header.build_id),
            .path = try arena.dupe(u8, header.path),
            .segments = try arena.dupe(Segment, header.segments),
            .sizes = header.sizes,
        };
    }
};

pub const Chunk = struct {
    section: Section,
    offset: u64,
    bytes: []const u8,
};

test "Header.clone copies the identity, the segments and the sizes" {
    const segments = [_]Header.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x200 }};
    var sizes = std.EnumArray(Section, u64).initFill(0);
    sizes.set(.dynsym, 240);
    const original = Header{
        .build_id = "\x01\x02\x03\x04",
        .path = "/usr/lib/libx.so",
        .segments = &segments,
        .sizes = sizes,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copy = try original.clone(arena.allocator());
    try std.testing.expectEqualSlices(u8, original.build_id, copy.build_id);
    try std.testing.expectEqual(@as(u64, 0x401000), copy.segments[0].vaddr);
    try std.testing.expectEqual(@as(u64, 240), copy.sizes.get(.dynsym));
    try std.testing.expect(copy.segments.ptr != original.segments.ptr);
}
