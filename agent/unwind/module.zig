//! The unwind information of one loaded executable or library, ready to be searched by address.
const std = @import("std");
const ehframe = @import("core/ehframe.zig");
const sections = @import("core/sections.zig");

/// One mapping of a file, as `/proc/<pid>/maps` gives it.
pub const Mapping = struct {
    file: []const u8,
    start: u64,
    end: u64,
    offset: u64,
};

pub const Module = struct {
    /// The executable mapping in the process: start <= pc < end.
    start: u64,
    end: u64,
    /// The address in memory is the address written in the file plus this.
    bias: u64,
    /// Sorted by where they begin, without empty ranges, and assumed not to overlap (the
    /// linker makes them so). They point into the file's bytes, which must outlive the module.
    fdes: []const ehframe.Fde,
    /// False for a mapping whose file has no unwind information. Addresses in it are still
    /// known to be code.
    has_unwind: bool = true,

    /// The bytes of the file, for reading the code before a return address. Empty if unknown.
    image: []const u8 = &.{},
    /// The executable segment the mapping belongs to, as written in the file. Size 0 if unknown.
    seg_offset: u64 = 0,
    seg_vaddr: u64 = 0,
    seg_size: u64 = 0,

    pub fn load(module: *Module, gpa: std.mem.Allocator, mapping: Mapping) !void {
        const section = (try sections.find(mapping.file, ".eh_frame")) orelse return error.NoUnwindInfo;
        const bytes = sections.bytesOf(mapping.file, section) orelse return error.NoUnwindInfo;
        const bias = (try sections.loadBias(mapping.file, mapping.start, mapping.offset)) orelse return error.NoUnwindInfo;

        var list: std.ArrayList(ehframe.Fde) = .empty;
        errdefer list.deinit(gpa);
        var it = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        while (try it.next()) |fde| {
            // A function the linker dropped keeps an entry with an empty range.
            if (fde.pc_end > fde.pc_begin) try list.append(gpa, fde);
        }
        std.mem.sort(ehframe.Fde, list.items, {}, byBegin);
        const seg = (try sections.mappedSegment(mapping.file, mapping.offset)) orelse return error.NoUnwindInfo;

        module.* = .{
            .start = mapping.start,
            .end = mapping.end,
            .bias = bias,
            .fdes = try list.toOwnedSlice(gpa),
            .image = mapping.file,
            .seg_offset = seg.offset,
            .seg_vaddr = seg.vaddr,
            .seg_size = seg.filesz,
        };
    }

    pub fn deinit(module: *Module, gpa: std.mem.Allocator) void {
        gpa.free(module.fdes);
        module.* = undefined;
    }
};

fn byBegin(_: void, a: ehframe.Fde, b: ehframe.Fde) bool {
    return a.pc_begin < b.pc_begin;
}
