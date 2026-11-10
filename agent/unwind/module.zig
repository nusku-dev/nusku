//! The unwind table of one binary.

const std = @import("std");
const assert = std.debug.assert;
const eh_frame = @import("../elf/elf.zig").eh_frame;
const elf = @import("shared").elf;
const go_pclntab = @import("go_pclntab.zig");
const table = @import("table.zig");

pub const Mapping = struct {
    file: []const u8,
    start: u64,
    end: u64,
    offset: u64,
};

pub const Source = enum { eh_frame, go_pclntab };

pub const Built = struct {
    bias: u64,
    source: Source,
    fdes_debug_frame: u32 = 0,
};

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
        if (fde.pc_end > fde.pc_begin) try fdes.append(gpa, fde);
    }
    std.mem.sortUnstable(eh_frame.Fde, fdes.items, {}, fde_less_than);
    return fdes.toOwnedSlice(gpa);
}

fn fdes_merge(
    gpa: std.mem.Allocator,
    eh: []const eh_frame.Fde,
    debug: []const eh_frame.Fde,
) ![]eh_frame.Fde {
    const out = try gpa.alloc(eh_frame.Fde, eh.len + debug.len);
    errdefer gpa.free(out);
    @memcpy(out[0..eh.len], eh);

    var count = eh.len;
    var debug_end: u64 = 0;
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

fn fdes_overlap(sorted: []const eh_frame.Fde, fde: eh_frame.Fde) bool {
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

const testing = std.testing;

fn fde_test(pc_begin: u64, pc_end: u64) eh_frame.Fde {
    return .{ .pc_begin = pc_begin, .pc_end = pc_end, .cie = undefined, .instructions = &.{} };
}

test "a merge keeps .eh_frame, and adds .debug_frame only where nothing else is" {
    const eh = [_]eh_frame.Fde{ fde_test(0x1000, 0x1100), fde_test(0x1200, 0x1300) };
    const debug = [_]eh_frame.Fde{
        fde_test(0x0f00, 0x1000),
        fde_test(0x1000, 0x1100),
        fde_test(0x1100, 0x1200),
        fde_test(0x1150, 0x1180),
        fde_test(0x12f0, 0x1310),
        fde_test(0x1300, 0x1400),
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

const target_layer = @import("../target/target.zig");
const process = @import("../os/os.zig").process;
const elf_file = @import("../elf/elf.zig").file;
const File = @import("shared").File;

test "C built without unwind tables (musl's, here) gets its rows from .debug_frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const address = @intFromPtr(&std.c.clock_gettime);
    var own = try target_layer.Target.init(testing.allocator, process.current_pid());
    defer own.deinit(testing.allocator);
    const mapping = for (own.regions) |found| {
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

    const eh = try fdes_of(testing.allocator, loaded.bytes, ".eh_frame", .eh_frame);
    defer testing.allocator.free(eh);
    if (fdes_overlap(eh, fde_test(file_address, file_address + 1))) return error.SkipZigTest;

    try testing.expect(built.fdes_debug_frame > 0);
    const row = target.find(file_address) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromEnum(table.CfaType.rsp), row.cfa_type);
    try testing.expectEqual(@as(i32, 8), row.cfa_offset);
}
