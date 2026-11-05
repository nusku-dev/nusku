//! The unwind table of one mapped executable or library, from whichever source it has: Go's
//! pclntab for a Go binary, .eh_frame for everything else, and .debug_frame for the code that
//! .eh_frame does not cover.

const std = @import("std");
const assert = std.debug.assert;
const eh_frame = @import("eh_frame.zig");
const elf = @import("shared").elf;
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
    /// Functions described by .debug_frame only: code built without unwind tables.
    fdes_debug_frame: u32 = 0,
};

/// Builds the table of the file behind `mapping` into `target`.
///
/// A Go binary has no .eh_frame for its Go code, so its pclntab wins when it has one. (Its C
/// code, in a cgo binary, then has no rows: frame pointers unwind it, as before.)
pub fn table_build(target: *table.Table, gpa: std.mem.Allocator, mapping: Mapping) !Built {
    assert(mapping.start < mapping.end);
    const bias_found = try elf.load_bias(mapping.file, mapping.start, mapping.offset);
    const bias = bias_found orelse return error.NoUnwindInfo;

    if (try elf.find(mapping.file, ".gopclntab")) |section| {
        const bytes = elf.bytes_of(mapping.file, section) orelse return error.NoUnwindInfo;
        const text = (try elf.find(mapping.file, ".text")) orelse
            return error.NoUnwindInfo;
        const pclntab = try go_pclntab.Pclntab.init(bytes, text.vaddr);
        try target.init_go(gpa, &pclntab);
        return .{ .bias = bias, .source = .go_pclntab };
    }

    const eh = try fdes_of(gpa, mapping.file, ".eh_frame", .eh_frame);
    defer gpa.free(eh);
    // Only an unstripped file has it, and only for its code without .eh_frame entries it adds
    // anything. A .debug_frame that cannot be read is ignored: .eh_frame alone is what the
    // module had before.
    const debug = fdes_of(gpa, mapping.file, ".debug_frame", .debug_frame) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => &.{},
        };
    defer gpa.free(debug);
    if (eh.len == 0 and debug.len == 0) return error.NoUnwindInfo;

    const fdes = try fdes_merge(gpa, eh, debug);
    defer gpa.free(fdes);
    try target.init(gpa, fdes);
    return .{
        .bias = bias,
        .source = .eh_frame,
        .fdes_debug_frame = @intCast(fdes.len - eh.len),
    };
}

/// The FDEs of one section, sorted by `pc_begin`, without empty ranges. Empty when the file
/// does not have the section. They point into `file`.
fn fdes_of(
    gpa: std.mem.Allocator,
    file: []const u8,
    name: []const u8,
    format: eh_frame.Format,
) ![]eh_frame.Fde {
    const section = (try elf.find(file, name)) orelse return &.{};
    const bytes = elf.bytes_of(file, section) orelse return &.{};

    var fdes: std.ArrayList(eh_frame.Fde) = .empty;
    errdefer fdes.deinit(gpa);
    const reader = eh_frame.EhFrame{ .bytes = bytes, .vaddr = section.vaddr, .format = format };
    var iterator = reader.iterator();
    while (try iterator.next()) |fde| {
        // A function the linker dropped keeps an entry with an empty range.
        if (fde.pc_end > fde.pc_begin) try fdes.append(gpa, fde);
    }
    std.mem.sortUnstable(eh_frame.Fde, fdes.items, {}, fde_less_than);
    return fdes.toOwnedSlice(gpa);
}

/// Every FDE of `eh`, and those of `debug` that overlap none of them nor each other, sorted.
/// Where both describe a function, .eh_frame wins: it is what the program itself unwinds with.
/// Both are sorted.
fn fdes_merge(
    gpa: std.mem.Allocator,
    eh: []const eh_frame.Fde,
    debug: []const eh_frame.Fde,
) ![]eh_frame.Fde {
    const out = try gpa.alloc(eh_frame.Fde, eh.len + debug.len);
    errdefer gpa.free(out);
    @memcpy(out[0..eh.len], eh);

    var count = eh.len;
    var debug_end: u64 = 0; // Where the last kept .debug_frame FDE ends.
    for (debug) |fde| {
        if (fde.pc_begin < debug_end) continue;
        if (fdes_overlap(eh, fde)) continue;
        out[count] = fde;
        count += 1;
        debug_end = fde.pc_end;
    }
    std.mem.sortUnstable(eh_frame.Fde, out[0..count], {}, fde_less_than);
    return gpa.realloc(out, count);
}

/// Whether `fde` shares an address with one of `sorted`, which do not overlap each other.
fn fdes_overlap(sorted: []const eh_frame.Fde, fde: eh_frame.Fde) bool {
    // The first one that ends after `fde` begins: the only one that can overlap it.
    var low: usize = 0;
    var high: usize = sorted.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (sorted[middle].pc_end <= fde.pc_begin) low = middle + 1 else high = middle;
    }
    return low < sorted.len and sorted[low].pc_begin < fde.pc_end;
}

fn fde_less_than(_: void, a: eh_frame.Fde, b: eh_frame.Fde) bool {
    return a.pc_begin < b.pc_begin;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn fde_test(pc_begin: u64, pc_end: u64) eh_frame.Fde {
    return .{ .pc_begin = pc_begin, .pc_end = pc_end, .cie = undefined, .instructions = &.{} };
}

test "a merge keeps .eh_frame, and adds .debug_frame only where nothing else is" {
    const eh = [_]eh_frame.Fde{ fde_test(0x1000, 0x1100), fde_test(0x1200, 0x1300) };
    const debug = [_]eh_frame.Fde{
        fde_test(0x0f00, 0x1000), // Before: kept.
        fde_test(0x1000, 0x1100), // The same function as .eh_frame: dropped.
        fde_test(0x1100, 0x1200), // In the gap: kept.
        fde_test(0x1150, 0x1180), // Overlaps the one before it: dropped.
        fde_test(0x12f0, 0x1310), // Overlaps the end of an .eh_frame one: dropped.
        fde_test(0x1300, 0x1400), // After: kept.
    };
    const merged = try fdes_merge(testing.allocator, &eh, &debug);
    defer testing.allocator.free(merged);

    const starts = [_]u64{ 0x0f00, 0x1000, 0x1100, 0x1200, 0x1300 };
    try testing.expectEqual(starts.len, merged.len);
    for (starts, merged) |start, fde| try testing.expectEqual(start, fde.pc_begin);

    const none = try fdes_merge(testing.allocator, &eh, &.{});
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 2), none.len);
}

const process_maps = @import("../target/process_maps.zig");
const process = @import("../os/process.zig");
const elf_file = @import("elf_file.zig");
const File = @import("shared").File;

test "C built without unwind tables (musl's, here) gets its rows from .debug_frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Where clock_gettime is in this process, and the file mapped there.
    const address = @intFromPtr(&std.c.clock_gettime);
    const mappings = try process_maps.read(arena.allocator(), process.current_pid());
    const mapping = for (mappings) |found| {
        if (address >= found.start and address < found.end) break found;
    } else return error.SkipZigTest;
    if (mapping.path.len == 0 or mapping.path[0] != '/') return error.SkipZigTest;

    var file = try File.open(try arena.allocator().dupeZ(u8, mapping.path));
    defer file.deinit();
    var loaded = try elf_file.load(&file, &elf_file.sections_unwind, elf_file.file_size_max);
    defer loaded.deinit();

    var target: table.Table = undefined;
    const built = try table_build(&target, testing.allocator, .{
        .file = loaded.bytes,
        .start = mapping.start,
        .end = mapping.end,
        .offset = mapping.offset,
    });
    defer target.deinit(testing.allocator);
    const file_address = address - built.bias;

    // A libc with .eh_frame for it (glibc) has nothing to show here.
    const eh = try fdes_of(testing.allocator, loaded.bytes, ".eh_frame", .eh_frame);
    defer testing.allocator.free(eh);
    if (fdes_overlap(eh, fde_test(file_address, file_address + 1))) return error.SkipZigTest;

    // At the first instruction, the return address is right at rsp.
    try testing.expect(built.fdes_debug_frame > 0);
    const row = target.find(file_address) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromEnum(table.CfaType.rsp), row.cfa_type);
    try testing.expectEqual(@as(i32, 8), row.cfa_offset);
}
