//! The unwind information of one loaded executable or library, ready to be searched by address.
const std = @import("std");
const ehframe = @import("ehframe.zig");
const sections = @import("sections.zig");

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

    pub const LoadError = error{NoUnwindInfo} || sections.Error || ehframe.Error || std.mem.Allocator.Error;

    /// `start`, `end` and `offset` describe one mapping of the file in the process: where it is
    /// in memory and which offset of the file it begins at.
    pub fn load(allocator: std.mem.Allocator, file: []const u8, start: u64, end: u64, offset: u64) LoadError!Module {
        const section = (try sections.find(file, ".eh_frame")) orelse return error.NoUnwindInfo;
        const bytes = sections.bytesOf(file, section) orelse return error.NoUnwindInfo;
        const bias = (try sections.loadBias(file, start, offset)) orelse return error.NoUnwindInfo;

        var list: std.ArrayList(ehframe.Fde) = .empty;
        errdefer list.deinit(allocator);
        var it = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        while (try it.next()) |fde| {
            // A function the linker dropped keeps an entry with an empty range.
            if (fde.pc_end > fde.pc_begin) try list.append(allocator, fde);
        }
        std.mem.sort(ehframe.Fde, list.items, {}, byBegin);
        const seg = (try sections.mappedSegment(file, offset)) orelse return error.NoUnwindInfo;
        return .{
            .start = start,
            .end = end,
            .bias = bias,
            .fdes = try list.toOwnedSlice(allocator),
            .image = file,
            .seg_offset = seg.offset,
            .seg_vaddr = seg.vaddr,
            .seg_size = seg.filesz,
        };
    }

    /// An executable mapping whose file has no unwind information, or none that could be read.
    /// Frames in it can only be followed through the frame pointer chain.
    pub fn withoutUnwindInfo(start: u64, end: u64) Module {
        return .{ .start = start, .end = end, .bias = 0, .fdes = &.{}, .has_unwind = false };
    }

    /// Like `withoutUnwindInfo`, but the code can be read: `file` is the file's bytes and `offset`
    /// the file offset the mapping starts at. If the file's layout is not understood, the module
    /// simply has no readable code.
    pub fn codeOnly(start: u64, end: u64, file: []const u8, offset: u64) Module {
        var m = withoutUnwindInfo(start, end);
        const seg = (sections.mappedSegment(file, offset) catch return m) orelse return m;
        m.bias = start -% offset -% seg.vaddr +% seg.offset;
        m.image = file;
        m.seg_offset = seg.offset;
        m.seg_vaddr = seg.vaddr;
        m.seg_size = seg.filesz;
        return m;
    }

    /// `len` bytes of code starting at the memory address `addr`, or null if they are not all
    /// inside the executable segment, or the module does not know its code.
    pub fn codeAt(self: Module, addr: u64, len: usize) ?[]const u8 {
        if (self.seg_size == 0 or addr < self.bias) return null;
        const vaddr = addr - self.bias;
        if (vaddr < self.seg_vaddr) return null;
        const rel = vaddr - self.seg_vaddr;
        if (rel > self.seg_size or self.seg_size - rel < len) return null;
        const start = std.math.add(u64, self.seg_offset, rel) catch return null;
        const stop = std.math.add(u64, start, len) catch return null;
        if (stop > self.image.len) return null;
        return self.image[@intCast(start)..@intCast(stop)];
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.fdes);
        self.* = undefined;
    }

    pub fn contains(self: Module, pc: u64) bool {
        return pc >= self.start and pc < self.end;
    }

    /// The function that covers the address `pc` (an address in memory), or null.
    pub fn find(self: Module, pc: u64) ?ehframe.Fde {
        if (pc < self.bias) return null;
        const addr = pc - self.bias;

        // The number of functions that begin at or below the address.
        var lo: usize = 0;
        var hi: usize = self.fdes.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.fdes[mid].pc_begin <= addr) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const fde = self.fdes[lo - 1];
        return if (addr < fde.pc_end) fde else null;
    }
};

fn byBegin(_: void, a: ehframe.Fde, b: ehframe.Fde) bool {
    return a.pc_begin < b.pc_begin;
}

// ------------------------------------------------------------------ tests

fn testFde(begin: u64, end: u64) ehframe.Fde {
    return .{
        .pc_begin = begin,
        .pc_end = end,
        .cie = .{
            .offset = 0,
            .code_align = 1,
            .data_align = -8,
            .ra_register = 16,
            .fde_encoding = 0x1b,
            .signal_frame = false,
            .has_augmentation = true,
            .instructions = &.{},
        },
        .instructions = &.{},
    };
}

test "find: the function covering an address, with the load bias applied" {
    const fdes = [_]ehframe.Fde{ testFde(0x1000, 0x1010), testFde(0x1010, 0x1020), testFde(0x2000, 0x2040) };
    const m = Module{ .start = 0x6000, .end = 0x8000, .bias = 0x5000, .fdes = &fdes };

    try std.testing.expectEqual(@as(u64, 0x1000), m.find(0x6000).?.pc_begin);
    try std.testing.expectEqual(@as(u64, 0x1000), m.find(0x600f).?.pc_begin);
    try std.testing.expectEqual(@as(u64, 0x1010), m.find(0x6010).?.pc_begin);
    try std.testing.expectEqual(@as(u64, 0x1010), m.find(0x601f).?.pc_begin);
    try std.testing.expect(m.find(0x6020) == null); // in the gap
    try std.testing.expect(m.find(0x6fff) == null);
    try std.testing.expectEqual(@as(u64, 0x2000), m.find(0x7000).?.pc_begin);
    try std.testing.expectEqual(@as(u64, 0x2000), m.find(0x703f).?.pc_begin);
    try std.testing.expect(m.find(0x7040) == null);
    try std.testing.expect(m.find(0x4fff) == null); // below the bias
    try std.testing.expect(m.find(0) == null);
    try std.testing.expect(m.find(std.math.maxInt(u64)) == null);
}

test "contains: the end of a mapping is exclusive" {
    const m = Module{ .start = 0x6000, .end = 0x8000, .bias = 0, .fdes = &.{} };
    try std.testing.expect(!m.contains(0x5fff));
    try std.testing.expect(m.contains(0x6000));
    try std.testing.expect(m.contains(0x7fff));
    try std.testing.expect(!m.contains(0x8000));
}

test "a module with no functions finds nothing" {
    const m = Module{ .start = 0, .end = 0x1000, .bias = 0, .fdes = &.{} };
    try std.testing.expect(m.find(0x10) == null);
}

test "a mapping without unwind information has addresses and no functions" {
    const m = Module.withoutUnwindInfo(0x6000, 0x8000);
    try std.testing.expect(m.contains(0x7000));
    try std.testing.expect(!m.contains(0x8000));
    try std.testing.expect(m.find(0x7000) == null);
    try std.testing.expect(!m.has_unwind);
}

test "codeAt reads the bytes of the code at a memory address" {
    var image: [0x40]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @intCast(i);
    const m = Module{
        .start = 0x6000,
        .end = 0x7000,
        .bias = 0x5000,
        .fdes = &.{},
        .image = &image,
        .seg_offset = 0x10,
        .seg_vaddr = 0x1010,
        .seg_size = 0x20,
    };

    // Memory 0x6014 is address 0x1014 in the file, 4 bytes into the segment: file offset 0x14.
    try std.testing.expectEqualSlices(u8, &.{ 0x14, 0x15, 0x16, 0x17 }, m.codeAt(0x6014, 4).?);
    try std.testing.expectEqual(@as(u8, 0x10), m.codeAt(0x6010, 1).?[0]); // the first byte
    try std.testing.expectEqualSlices(u8, &.{ 0x2c, 0x2d, 0x2e, 0x2f }, m.codeAt(0x602c, 4).?); // the last four
    try std.testing.expect(m.codeAt(0x602d, 4) == null); // runs past the end of the segment
    try std.testing.expect(m.codeAt(0x6030, 1) == null);
    try std.testing.expect(m.codeAt(0x600f, 1) == null); // before the segment
    try std.testing.expect(m.codeAt(0x4000, 1) == null); // below the bias
    try std.testing.expect(Module.withoutUnwindInfo(0x6000, 0x7000).codeAt(0x6014, 4) == null);
}
