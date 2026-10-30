//! The unwind information of one mapped executable or library: its FDEs, sorted by address,
//! and the bias that turns the file's addresses into the process's.

const std = @import("std");
const assert = std.debug.assert;
const eh_frame = @import("eh_frame.zig");
const elf_sections = @import("elf_sections.zig");

/// One executable mapping of a file, as `/proc/<pid>/maps` gives it.
pub const Mapping = struct {
    /// The file's bytes, at their file offsets (see elf_file.zig).
    file: []const u8,
    start: u64,
    end: u64,
    offset: u64,
};

pub const Module = struct {
    /// Runtime address = file address + bias.
    bias: u64,
    /// Sorted by `pc_begin`, without empty ranges, and assumed not to overlap: the linker makes
    /// them so, and table.zig refuses overlaps. They point into the file's bytes, which must
    /// outlive the module.
    fdes: []const eh_frame.Fde,

    pub fn load(module: *Module, gpa: std.mem.Allocator, mapping: Mapping) !void {
        assert(mapping.start < mapping.end);

        const section = (try elf_sections.find(mapping.file, ".eh_frame")) orelse
            return error.NoUnwindInfo;
        const bytes = elf_sections.bytes_of(mapping.file, section) orelse
            return error.NoUnwindInfo;
        const bias_found = try elf_sections.load_bias(mapping.file, mapping.start, mapping.offset);
        const bias = bias_found orelse return error.NoUnwindInfo;

        var fdes: std.ArrayList(eh_frame.Fde) = .empty;
        errdefer fdes.deinit(gpa);
        var iterator = (eh_frame.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        while (try iterator.next()) |fde| {
            // A function the linker dropped keeps an entry with an empty range.
            if (fde.pc_end > fde.pc_begin) try fdes.append(gpa, fde);
        }
        std.mem.sortUnstable(eh_frame.Fde, fdes.items, {}, fde_less_than);

        module.* = .{ .bias = bias, .fdes = try fdes.toOwnedSlice(gpa) };
    }

    pub fn deinit(module: *Module, gpa: std.mem.Allocator) void {
        gpa.free(module.fdes);
        module.* = undefined;
    }
};

fn fde_less_than(_: void, a: eh_frame.Fde, b: eh_frame.Fde) bool {
    return a.pc_begin < b.pc_begin;
}
