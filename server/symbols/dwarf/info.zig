//! DWARF debug info: Stores parsed DWARF debug information and provides address-to-source lookup.

const std = @import("std");
const tables = @import("tables.zig");
const b = @import("builder.zig");

const Builder = b.Builder;
const Sections = b.Sections;

const assert = std.debug.assert;

pub const depth_max = 32;
pub const no_file = std.math.maxInt(u32);

pub const Location = struct {
    function: ?[]const u8,
    file: ?[]const u8,
    line: u32,
    inlined: bool,
};

pub const Func = struct {
    name: ?[]const u8,
    ranges_first: u32,
    ranges_count: u32,
    depth: u16,
    end: u32,
    call_file: u32,
    call_line: u32,
};

pub const Range = struct { low: u64, high: u64 };
pub const Root = struct { low: u64, high: u64, func: u32 };

pub const DebugInfo = struct {
    arena: std.heap.ArenaAllocator,
    funcs: []Func,
    ranges: []Range,
    roots: []Root,
    rows: []tables.Row,
    files: [][]const u8,
    strings_bytes: u64,

    pub fn deinit(info: *DebugInfo, gpa: std.mem.Allocator) void {
        gpa.free(info.funcs);
        gpa.free(info.ranges);
        gpa.free(info.roots);
        gpa.free(info.rows);
        gpa.free(info.files);
        info.arena.deinit();
        info.* = undefined;
    }

    pub fn bytes(info: *const DebugInfo) u64 {
        return info.funcs.len * @sizeOf(Func) + info.ranges.len * @sizeOf(Range) +
            info.roots.len * @sizeOf(Root) + info.rows.len * @sizeOf(tables.Row) +
            info.files.len * @sizeOf([]const u8) + info.strings_bytes;
    }

    pub fn locate(info: *const DebugInfo, address: u64, out: *[depth_max]Location) []Location {
        var chain: [depth_max]u32 = undefined;
        const depth = info.chain_find(address, &chain);
        const row = tables.row_find(info.rows, address);
        if (depth == 0) {
            const found = row orelse return out[0..0];
            out[0] = .{
                .function = null,
                .file = info.file(found.file),
                .line = found.line,
                .inlined = false,
            };
            return out[0..1];
        }
        var file_at: ?[]const u8 = if (row) |found| info.file(found.file) else null;
        var line_at: u32 = if (row) |found| found.line else 0;
        for (0..depth) |k| {
            const func = &info.funcs[chain[depth - 1 - k]];
            out[k] = .{
                .function = func.name,
                .file = file_at,
                .line = line_at,
                .inlined = k + 1 < depth,
            };
            file_at = info.file(func.call_file);
            line_at = func.call_line;
        }
        return out[0..depth];
    }

    fn chain_find(info: *const DebugInfo, address: u64, chain: *[depth_max]u32) usize {
        const root = info.root_find(address) orelse return 0;
        chain[0] = root;
        var depth: usize = 1;
        var parent = root;
        var index = root + 1;
        while (index < info.funcs[parent].end and depth < depth_max) {
            const child = &info.funcs[index];
            if (child.depth == info.funcs[parent].depth + 1 and info.contains(child, address)) {
                chain[depth] = index;
                depth += 1;
                parent = index;
                index += 1;
            } else {
                index = @max(child.end, index + 1);
            }
        }
        return depth;
    }

    fn root_find(info: *const DebugInfo, address: u64) ?u32 {
        var low: usize = 0;
        var high: usize = info.roots.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (info.roots[middle].low <= address) low = middle + 1 else high = middle;
        }
        var index = low;
        var looked: u32 = 0;
        while (index > 0 and looked < 8) : (looked += 1) {
            index -= 1;
            const root = info.roots[index];
            if (address < root.high) return root.func;
        }
        return null;
    }

    fn contains(info: *const DebugInfo, func: *const Func, address: u64) bool {
        for (info.ranges[func.ranges_first..][0..func.ranges_count]) |range| {
            if (address >= range.low and address < range.high) return true;
        }
        return false;
    }

    fn file(info: *const DebugInfo, index: u32) ?[]const u8 {
        return if (index < info.files.len) info.files[index] else null;
    }
};
