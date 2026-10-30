//! The unwind table of one mapped executable or library, from whichever source it has: Go's
//! pclntab for a Go binary, .eh_frame for everything else.

const std = @import("std");
const assert = std.debug.assert;
const eh_frame = @import("eh_frame.zig");
const elf_sections = @import("elf_sections.zig");
const go_pclntab = @import("go_pclntab.zig");
const table = @import("table.zig");

/// One executable mapping of a file, as `/proc/<pid>/maps` gives it.
pub const Mapping = struct {
    /// The file's bytes, at their file offsets (see elf_file.zig).
    file: []const u8,
    start: u64,
    end: u64,
    offset: u64,
};

pub const Source = enum { eh_frame, go_pclntab };

pub const Built = struct {
    /// Runtime address = file address + bias.
    bias: u64,
    source: Source,
};

/// Builds the table of the file behind `mapping` into `target`.
///
/// A Go binary has no .eh_frame for its Go code, so its pclntab wins when it has one. (Its C
/// code, in a cgo binary, then has no rows: frame pointers unwind it, as before.)
pub fn table_build(target: *table.Table, gpa: std.mem.Allocator, mapping: Mapping) !Built {
    assert(mapping.start < mapping.end);
    const bias_found = try elf_sections.load_bias(mapping.file, mapping.start, mapping.offset);
    const bias = bias_found orelse return error.NoUnwindInfo;

    if (try elf_sections.find(mapping.file, ".gopclntab")) |section| {
        const bytes = elf_sections.bytes_of(mapping.file, section) orelse return error.NoUnwindInfo;
        const text = (try elf_sections.find(mapping.file, ".text")) orelse
            return error.NoUnwindInfo;
        const pclntab = try go_pclntab.Pclntab.init(bytes, text.vaddr);
        try target.init_go(gpa, &pclntab);
        return .{ .bias = bias, .source = .go_pclntab };
    }

    const section = (try elf_sections.find(mapping.file, ".eh_frame")) orelse
        return error.NoUnwindInfo;
    const bytes = elf_sections.bytes_of(mapping.file, section) orelse return error.NoUnwindInfo;
    const fdes = try fdes_sorted(gpa, bytes, section.vaddr);
    defer gpa.free(fdes);
    try target.init(gpa, fdes);
    return .{ .bias = bias, .source = .eh_frame };
}

/// The FDEs of an .eh_frame section, sorted by `pc_begin`, without empty ranges. They point
/// into `bytes`.
fn fdes_sorted(gpa: std.mem.Allocator, bytes: []const u8, vaddr: u64) ![]eh_frame.Fde {
    var fdes: std.ArrayList(eh_frame.Fde) = .empty;
    errdefer fdes.deinit(gpa);
    var iterator = (eh_frame.EhFrame{ .bytes = bytes, .vaddr = vaddr }).iterator();
    while (try iterator.next()) |fde| {
        // A function the linker dropped keeps an entry with an empty range.
        if (fde.pc_end > fde.pc_begin) try fdes.append(gpa, fde);
    }
    std.mem.sortUnstable(eh_frame.Fde, fdes.items, {}, fde_less_than);
    return fdes.toOwnedSlice(gpa);
}

fn fde_less_than(_: void, a: eh_frame.Fde, b: eh_frame.Fde) bool {
    return a.pc_begin < b.pc_begin;
}
