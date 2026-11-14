//! build and Parses DWARF sections and builds the debug information

const std = @import("std");
const decoder = @import("decoder.zig");
const reader = @import("reader.zig");
const tables = @import("tables.zig");
const i = @import("info.zig");
const ab = @import("abbrev.zig");

const Reader = reader.Reader;
const Value = decoder.Value;
const Abbrevs = ab.Abbrevs;
pub const Error = reader.Error;

const Func = i.Func;
const Range = i.Range;
const Root = i.Root;
const DebugInfo = i.DebugInfo;

const Die = struct {
    tag: u64,
    name: ?Value = null,
    linkage_name: ?Value = null,
    origin: ?Value = null,
    specification: ?Value = null,
    low_pc: ?Value = null,
    high_pc: ?Value = null,
    ranges: ?Value = null,
    call_file: ?u64 = null,
    call_line: ?u64 = null,
    stmt_list: ?u64 = null,
    comp_dir: ?Value = null,
    str_offsets_base: ?u64 = null,
    addr_base: ?u64 = null,
    rnglists_base: ?u64 = null,

    fn take(die: *Die, attr: u64, value: Value) void {
        switch (attr) {
            0x03 => die.name = value,
            0x6e, 0x2007 => die.linkage_name = value,
            0x31 => die.origin = value,
            0x47 => die.specification = value,
            0x11 => die.low_pc = value,
            0x12 => die.high_pc = value,
            0x55 => die.ranges = value,
            0x58 => die.call_file = value.number(),
            0x59 => die.call_line = value.number(),
            0x10 => die.stmt_list = value.number(),
            0x1b => die.comp_dir = value,
            0x72 => die.str_offsets_base = value.number(),
            0x73 => die.addr_base = value.number(),
            0x74 => die.rnglists_base = value.number(),
            else => {},
        }
    }
};

pub const Sections = struct {
    info: []const u8 = &.{},
    abbrev: []const u8 = &.{},
    line: []const u8 = &.{},
    str: []const u8 = &.{},
    line_str: []const u8 = &.{},
    addr: []const u8 = &.{},
    str_offsets: []const u8 = &.{},
    ranges: []const u8 = &.{},
    rnglists: []const u8 = &.{},
};

const Unit = struct {
    offset: u64,
    end: u64,
    dies: u64,
    abbrev_offset: u64,
    format: decoder.Unit,
};

const Bases = struct {
    str_offsets: u64 = 0,
    addr: u64 = 0,
    rnglists: u64 = 0,
    low_pc: u64 = 0,
    files: tables.Files = .{ .first = 0, .count = 0, .base = 1 },
};

const Open = struct {
    func: u32,
    die_depth: u32,
};

const tag_subprogram = 0x2e;
const tag_inlined = 0x1d;
const ut_compile = 1;
const ut_partial = 3;

const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sections: Sections,

    units: std.ArrayList(Unit) = .empty,
    abbrevs: std.AutoHashMapUnmanaged(u64, Abbrevs) = .empty,
    funcs: std.ArrayList(Func) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    roots: std.ArrayList(Root) = .empty,
    rows: std.ArrayList(tables.Row) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    strings_bytes: u64 = 0,

    fn init(gpa: std.mem.Allocator, sections: Sections) Builder {
        return .{
            .gpa = gpa,
            .arena = .init(gpa),
            .sections = sections,
        };
    }

    fn deinit(b: *Builder) void {
        var abbrevs = b.abbrevs.valueIterator();
        while (abbrevs.next()) |table| table.deinit(b.gpa);

        b.abbrevs.deinit(b.gpa);
        b.units.deinit(b.gpa);
        b.funcs.deinit(b.gpa);
        b.ranges.deinit(b.gpa);
        b.roots.deinit(b.gpa);
        b.rows.deinit(b.gpa);
        b.files.deinit(b.gpa);
        b.names.deinit(b.gpa);
        b.arena.deinit();
    }

    fn finish(b: *Builder) Error!DebugInfo {
        std.mem.sort(Root, b.roots.items, {}, root_less);
        std.mem.sort(tables.Row, b.rows.items, {}, tables.row_less);

        var result = DebugInfo{
            .arena = b.arena,
            .funcs = &.{},
            .ranges = &.{},
            .roots = &.{},
            .rows = &.{},
            .files = &.{},
            .strings_bytes = b.strings_bytes,
        };

        b.arena = .init(b.gpa);
        errdefer result.deinit(b.gpa);

        result.funcs = try b.funcs.toOwnedSlice(b.gpa);
        result.ranges = try b.ranges.toOwnedSlice(b.gpa);
        result.roots = try b.roots.toOwnedSlice(b.gpa);
        result.rows = try b.rows.toOwnedSlice(b.gpa);
        result.files = try b.files.toOwnedSlice(b.gpa);

        return result;
    }

    fn units_read(b: *Builder) Error!void {
        var r = Reader{ .bytes = b.sections.info };
        while (!r.done()) {
            const unit = unit_header(&r) catch break;
            r.at = @intCast(unit.end);
            if (unit.dies == 0) continue;
            try b.units.append(b.gpa, unit);
        }
        for (b.units.items) |*unit| b.unit_walk(unit) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Malformed => continue,
        };
    }

    fn unit_walk(b: *Builder, unit: *const Unit) Error!void {
        const abbrevs = try b.abbrevs_of(unit);
        const bytes = b.sections.info[0..@intCast(unit.end)];
        var r: Reader = undefined;
        r.init(bytes, @intCast(unit.dies));
        var bases = Bases{};
        var open: [i.depth_max * 4]Open = undefined;
        var open_count: usize = 0;
        var die_depth: u32 = 0;
        var first = true;
        while (!r.done()) {
            const code = try r.uleb();
            if (code == 0) {
                if (die_depth == 0) break;
                die_depth -= 1;
                continue;
            }
            const abbrev = abbrevs.find(code) orelse return error.Malformed;
            var die = try die_read(&r, abbrev, unit);
            while (open_count > 0 and open[open_count - 1].die_depth >= die_depth) {
                open_count -= 1;
                b.funcs.items[open[open_count].func].end = @intCast(b.funcs.items.len);
            }
            if (first) {
                first = false;
                try b.unit_start(&die, unit, &bases);
            } else if (die.tag == tag_subprogram or die.tag == tag_inlined) {
                const parent: ?u32 = if (open_count > 0) open[open_count - 1].func else null;
                if (try b.func_add(&die, unit, &bases, parent)) |index| {
                    if (abbrev.children and open_count < open.len) {
                        open[open_count] = .{ .func = index, .die_depth = die_depth };
                        open_count += 1;
                    } else {
                        b.funcs.items[index].end = index + 1;
                    }
                }
            }
            if (abbrev.children) die_depth += 1;
        }
        while (open_count > 0) {
            open_count -= 1;
            b.funcs.items[open[open_count].func].end = @intCast(b.funcs.items.len);
        }
    }

    fn unit_start(b: *Builder, die: *const Die, unit: *const Unit, bases: *Bases) Error!void {
        bases.str_offsets = die.str_offsets_base orelse 0;
        bases.addr = die.addr_base orelse 0;
        bases.rnglists = die.rnglists_base orelse 0;
        const low_pc = if (die.low_pc) |value| b.address_of(value, unit, bases) else null;
        bases.low_pc = low_pc orelse 0;
        const comp_dir_found = if (die.comp_dir) |value| b.string_of(value, unit, bases) else null;
        const comp_dir = comp_dir_found orelse "";
        const stmt_list = die.stmt_list orelse return;
        bases.files = tables.program_read(.{
            .line = b.sections.line,
            .line_str = b.sections.line_str,
            .str = b.sections.str,
        }, stmt_list, comp_dir, unit.format.address_size, .{
            .arena = b.arena.allocator(),
            .gpa = b.gpa,
            .files = &b.files,
            .rows = &b.rows,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Malformed => bases.files,
        };
    }

    fn func_add(b: *Builder, die: *const Die, unit: *const Unit, bases: *const Bases, parent: ?u32) Error!?u32 {
        const first: u32 = @intCast(b.ranges.items.len);
        try b.ranges_add(die, unit, bases);
        const count: u32 = @intCast(b.ranges.items.len - first);
        if (count == 0) return null;

        const inlined = die.tag == tag_inlined and parent != null;
        const index: u32 = @intCast(b.funcs.items.len);
        try b.funcs.append(b.gpa, .{
            .name = try b.name_of(die, unit, bases),
            .ranges_first = first,
            .ranges_count = count,
            .depth = if (inlined) b.funcs.items[parent.?].depth + 1 else 0,
            .end = index + 1,
            .call_file = if (die.call_file) |n| bases.files.global(n) orelse i.no_file else i.no_file,
            .call_line = @intCast(@min(die.call_line orelse 0, std.math.maxInt(u32))),
        });
        if (!inlined) {
            for (b.ranges.items[first..][0..count]) |range| {
                try b.roots.append(b.gpa, .{ .low = range.low, .high = range.high, .func = index });
            }
        }
        return index;
    }

    fn die_read(r: *Reader, abbrev: *const ab.Abbrev, unit: *const Unit) Error!Die {
        var die = Die{ .tag = abbrev.tag };
        for (abbrev.attrs) |attr| {
            const value = try decoder.value_read(r, attr.form, attr.implicit, unit.format);
            die.take(attr.name, value);
        }
        return die;
    }

    fn abbrevs_of(b: *Builder, unit: *const Unit) Error!Abbrevs {
        const entry = try b.abbrevs.getOrPut(b.gpa, unit.abbrev_offset);
        if (!entry.found_existing) {
            const at = unit.abbrev_offset;
            entry.value_ptr.* = Abbrevs.init(b.gpa, b.sections.abbrev, at) catch |err| {
                b.abbrevs.removeByPtr(entry.key_ptr);
                return err;
            };
        }
        return entry.value_ptr.*;
    }

    fn ranges_add(b: *Builder, die: *const Die, unit: *const Unit, bases: *const Bases) Error!void {
        if (die.low_pc) |low_value| {
            const low = b.address_of(low_value, unit, bases) orelse return;
            const high_value = die.high_pc orelse return;
            const high = switch (high_value) {
                .addr, .addrx => b.address_of(high_value, unit, bases) orelse return,
                else => low +| (high_value.number() orelse return),
            };
            if (high > low and low != 0) try b.ranges.append(b.gpa, .{ .low = low, .high = high });
            return;
        }
        const ranges = die.ranges orelse return;
        if (unit.format.version >= 5) {
            const at = switch (ranges) {
                .rnglistx => |index| bases.rnglists +|
                    (offset_entry(b.sections.rnglists, bases.rnglists, index, unit) orelse return),
                else => (ranges.number() orelse return),
            };
            b.rnglist_read(at, unit, bases) catch |err| if (err == error.OutOfMemory) return err;
        } else {
            const at = ranges.number() orelse return;
            b.ranges_v4_read(at, unit, bases) catch |err| if (err == error.OutOfMemory) return err;
        }
    }

    fn ranges_v4_read(b: *Builder, at: u64, unit: *const Unit, bases: *const Bases) Error!void {
        if (at >= b.sections.ranges.len) return error.Malformed;
        var r: Reader = undefined;
        r.init(b.sections.ranges, @intCast(at));
        const size = unit.format.address_size;
        const top: u64 = if (size == 4) std.math.maxInt(u32) else std.math.maxInt(u64);
        var base = bases.low_pc;
        while (true) {
            const start = try r.sized(size);
            const end = try r.sized(size);
            if (start == 0 and end == 0) return;
            if (start == top) {
                base = end;
                continue;
            }
            try b.range_put(base +% start, base +% end);
        }
    }

    fn rnglist_read(b: *Builder, at: u64, unit: *const Unit, bases: *const Bases) Error!void {
        if (at >= b.sections.rnglists.len) return error.Malformed;
        var r = Reader{ .bytes = b.sections.rnglists, .at = @intCast(at) };
        const size = unit.format.address_size;
        var base = bases.low_pc;
        while (true) {
            switch (try r.int(u8)) {
                0 => return,
                1 => base = try b.address_read(&r, unit, bases),
                2 => {
                    const start = try b.address_read(&r, unit, bases);
                    try b.range_put(start, try b.address_read(&r, unit, bases));
                },
                3 => {
                    const start = try b.address_read(&r, unit, bases);
                    try b.range_put(start, start +% try r.uleb());
                },
                4 => {
                    const start = try r.uleb();
                    try b.range_put(base +% start, base +% try r.uleb());
                },
                5 => base = try r.sized(size),
                6 => {
                    const start = try r.sized(size);
                    try b.range_put(start, try r.sized(size));
                },
                7 => {
                    const start = try r.sized(size);
                    try b.range_put(start, start +% try r.uleb());
                },
                else => return error.Malformed,
            }
        }
    }

    fn range_put(b: *Builder, low: u64, high: u64) Error!void {
        if (high <= low or low == 0) return;
        try b.ranges.append(b.gpa, .{ .low = low, .high = high });
    }

    fn name_of(b: *Builder, die_given: *const Die, unit_given: *const Unit, bases: *const Bases) Error!?[]const u8 {
        var die = die_given.*;
        var unit = unit_given.*;
        for (0..6) |_| {
            if (die.linkage_name orelse die.name) |value| {
                const text = b.string_of(value, &unit, bases) orelse return null;
                return try b.intern(text);
            }
            const target = die.origin orelse die.specification orelse return null;
            const at = switch (target) {
                .unit_ref => |n| unit.offset + n,
                .section_ref => |n| n,
                else => return null,
            };
            unit = b.unit_of(at) orelse return null;
            die = b.die_at(at, &unit) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.Malformed => return null,
            };
        }
        return null;
    }

    fn die_at(b: *Builder, at: u64, unit: *const Unit) Error!Die {
        const abbrevs = try b.abbrevs_of(unit);
        var r = Reader{ .bytes = b.sections.info[0..@intCast(unit.end)], .at = @intCast(at) };
        const abbrev = abbrevs.find(try r.uleb()) orelse return error.Malformed;
        return die_read(&r, abbrev, unit);
    }

    fn unit_of(b: *const Builder, at: u64) ?Unit {
        const units = b.units.items;
        var low: usize = 0;
        var high: usize = units.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (units[middle].offset <= at) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const unit = units[low - 1];
        return if (at >= unit.dies and at < unit.end) unit else null;
    }

    fn intern(b: *Builder, text: []const u8) Error![]const u8 {
        const entry = try b.names.getOrPut(b.gpa, text);
        if (!entry.found_existing) {
            const copy = try b.arena.allocator().dupe(u8, text);
            entry.key_ptr.* = copy;
            entry.value_ptr.* = copy;
            b.strings_bytes += copy.len;
        }
        return entry.value_ptr.*;
    }

    fn string_of(b: *const Builder, value: Value, unit: *const Unit, bases: *const Bases) ?[]const u8 {
        const offsets = b.sections.str_offsets;
        return switch (value) {
            .string => |text| text,
            .strp => |at| decoder.string_at(b.sections.str, at),
            .line_strp => |at| decoder.string_at(b.sections.line_str, at),
            .strx => |index| decoder.string_at(
                b.sections.str,
                offset_entry(offsets, bases.str_offsets, index, unit) orelse return null,
            ),
            else => null,
        };
    }

    fn address_of(b: *const Builder, value: Value, unit: *const Unit, bases: *const Bases) ?u64 {
        return switch (value) {
            .addr => |address| address,
            .addrx => |index| b.address_index(index, unit, bases),
            else => null,
        };
    }

    fn address_index(b: *const Builder, index: u64, unit: *const Unit, bases: *const Bases) ?u64 {
        const size = unit.format.address_size;
        const at = entry_at(bases.addr, index, size) orelse return null;
        var r = Reader{ .bytes = b.sections.addr, .at = at };
        if (r.at > r.bytes.len) return null;
        return r.sized(size) catch null;
    }
};

fn unit_header(r: *Reader) Error!Unit {
    const offset: u64 = r.at;
    var wide = false;
    const length = try r.length(&wide);
    const end = std.math.add(u64, r.at, length) catch return error.Malformed;
    if (end > r.bytes.len) return error.Malformed;
    const version = try r.int(u16);
    if (version < 2 or version > 5) {
        const skipped = decoder.Unit{ .version = version, .wide = wide, .address_size = 8 };
        return .{ .offset = offset, .end = end, .dies = 0, .abbrev_offset = 0, .format = skipped };
    }
    var unit = Unit{
        .offset = offset,
        .end = end,
        .dies = 0,
        .abbrev_offset = 0,
        .format = .{ .version = version, .wide = wide, .address_size = 8 },
    };
    if (version >= 5) {
        const kind = try r.int(u8);
        unit.format.address_size = try r.int(u8);
        unit.abbrev_offset = try r.offset(wide);
        if (kind != ut_compile and kind != ut_partial) return unit;
    } else {
        unit.abbrev_offset = try r.offset(wide);
        unit.format.address_size = try r.int(u8);
    }
    unit.dies = r.at;
    return unit;
}

fn root_less(_: void, a: Root, b: Root) bool {
    return a.low < b.low;
}

fn offset_entry(section: []const u8, base: u64, index: u64, unit: *const Unit) ?u64 {
    const size: u64 = if (unit.format.wide) 8 else 4;
    const at = entry_at(base, index, size) orelse return null;
    var r = Reader{ .bytes = section, .at = at };
    if (r.at > r.bytes.len) return null;
    return r.offset(unit.format.wide) catch null;
}

fn entry_at(base: u64, index: u64, size: u64) ?usize {
    const inside = std.math.mul(u64, index, size) catch return null;
    const at = std.math.add(u64, base, inside) catch return null;
    return std.math.cast(usize, at);
}

pub fn build(
    debugInfo: *DebugInfo,
    gpa: std.mem.Allocator,
    sections: Sections,
) Error!void {
    var builder = Builder.init(gpa, sections);
    defer builder.deinit();

    try builder.units_read();
    debugInfo.* = builder.finish();
}

const testing = std.testing;

fn func_test(name: []const u8, range: u32, depth: u16, end: u32, call: [2]u32) Func {
    return .{
        .name = name,
        .ranges_first = range,
        .ranges_count = 1,
        .depth = depth,
        .end = end,
        .call_file = call[0],
        .call_line = call[1],
    };
}

fn info_test(
    funcs: []Func,
    ranges: []Range,
    roots: []Root,
    rows: []tables.Row,
    files: [][]const u8,
) DebugInfo {
    return .{
        .arena = .init(testing.allocator),
        .funcs = funcs,
        .ranges = ranges,
        .roots = roots,
        .rows = rows,
        .files = files,
        .strings_bytes = 0,
    };
}

test "an address inside two inlined calls gives three frames, each with the line it is at" {
    var ranges = [_]Range{
        .{ .low = 0x1000, .high = 0x1100 },
        .{ .low = 0x1010, .high = 0x1040 },
        .{ .low = 0x1020, .high = 0x1030 },
        .{ .low = 0x1060, .high = 0x1070 },
    };
    var funcs = [_]Func{
        func_test("run", 0, 0, 4, .{ i.no_file, 0 }),
        func_test("outer", 1, 1, 3, .{ 0, 12 }),
        func_test("inner", 2, 2, 3, .{ 1, 40 }),
        func_test("other", 3, 1, 4, .{ 0, 20 }),
    };
    var roots = [_]Root{.{ .low = 0x1000, .high = 0x1100, .func = 0 }};
    var rows = [_]tables.Row{
        .{ .address = 0x1000, .file = 0, .line = 10, .end = false },
        .{ .address = 0x1020, .file = 2, .line = 7, .end = false },
        .{ .address = 0x1100, .file = 0, .line = 0, .end = true },
    };
    var files = [_][]const u8{ "/src/run.c", "/src/outer.h", "/src/inner.h" };
    var info = info_test(&funcs, &ranges, &roots, &rows, &files);
    defer info.arena.deinit();

    var out: [i.depth_max]i.Location = undefined;
    const frames = info.locate(0x1024, &out);
    try testing.expectEqual(@as(usize, 3), frames.len);
    try testing.expectEqualStrings("inner", frames[0].function.?);
    try testing.expectEqualStrings("/src/inner.h", frames[0].file.?);
    try testing.expectEqual(@as(u32, 7), frames[0].line);
    try testing.expect(frames[0].inlined);
    try testing.expectEqualStrings("outer", frames[1].function.?);
    try testing.expectEqualStrings("/src/outer.h", frames[1].file.?);
    try testing.expectEqual(@as(u32, 40), frames[1].line);
    try testing.expect(frames[1].inlined);
    try testing.expectEqualStrings("run", frames[2].function.?);
    try testing.expectEqualStrings("/src/run.c", frames[2].file.?);
    try testing.expectEqual(@as(u32, 12), frames[2].line);
    try testing.expect(!frames[2].inlined);

    const sibling = info.locate(0x1065, &out);
    try testing.expectEqual(@as(usize, 2), sibling.len);
    try testing.expectEqualStrings("other", sibling[0].function.?);
    try testing.expectEqual(@as(u32, 20), sibling[1].line);

    try testing.expectEqual(@as(usize, 0), info.locate(0x2000, &out).len);
}

// test "this machine's libc: its compressed DWARF 5 names an address with its source" {
//     const File = @import("shared").File;
//     const load = @import("dwarf_load.zig");
//     const elf = @import("shared").elf;
//     const gpa = testing.allocator;
//     var path_buffer: [128]u8 = undefined;
//     const path = libc_debug_path(&path_buffer) orelse return error.SkipZigTest;
//     var file = File.open(path) catch return error.SkipZigTest;
//     defer file.deinit();
//     const bytes = try gpa.alloc(u8, @intCast(try file.size_bytes()));
//     defer gpa.free(bytes);
//     _ = try file.read_at(bytes, 0);
//
//     var loaded = try load.from_elf(gpa, bytes);
//     defer loaded.deinit(gpa);
//     try testing.expect(loaded.owned[0] != null);
//     try testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, loaded.sections.info[4..6], .little));
//
//     var info = try DebugInfo.init(gpa, loaded.sections);
//     defer info.deinit(gpa);
//     const symtab = elf.bytes_of(bytes, (try elf.find(bytes, ".symtab")).?).?;
//     const strtab = elf.bytes_of(bytes, (try elf.find(bytes, ".strtab")).?).?;
//     var at: usize = 0;
//     const address = while (at + 24 <= symtab.len) : (at += 24) {
//         const name_at = std.mem.readInt(u32, symtab[at..][0..4], .little);
//         const name = std.mem.sliceTo(strtab[name_at..], 0);
//         if (std.mem.eql(u8, name, "__libc_start_call_main")) {
//             break std.mem.readInt(u64, symtab[at + 8 ..][0..8], .little);
//         }
//     } else return error.SkipZigTest;
//
//     var out: [i.depth_max]i.Location = undefined;
//     const frames = info.locate(address, &out);
//     try testing.expect(frames.len >= 1);
//     const outer = frames[frames.len - 1];
//     try testing.expectEqualStrings("__libc_start_call_main", outer.function.?);
//     try testing.expect(std.mem.endsWith(u8, outer.file.?, "libc_start_call_main.h"));
//     try testing.expect(outer.line > 0);
// }

fn libc_debug_path(buffer: []u8) ?[:0]const u8 {
    const File = @import("shared").File;
    var file = File.open("/usr/lib/x86_64-linux-gnu/libc.so.6") catch return null;
    defer file.deinit();
    var head: [64 * 1024]u8 = undefined;
    const got = file.read_at(&head, 0) catch return null;
    var from: usize = 12;
    while (std.mem.indexOfPos(u8, head[0..got], from, "GNU\x00")) |at| : (from = at + 4) {
        const size = std.mem.readInt(u32, head[at - 8 ..][0..4], .little);
        const kind = std.mem.readInt(u32, head[at - 4 ..][0..4], .little);
        if (kind != 3 or size < 2 or size > 32 or at + 4 + size > got) continue;
        return build_id_path(buffer, head[at + 4 ..][0..size]);
    }
    return null;
}

fn build_id_path(buffer: []u8, id: []const u8) ?[:0]const u8 {
    var hex: [64]u8 = undefined;
    for (id, 0..) |byte, idx| {
        hex[2 * idx] = "0123456789abcdef"[byte >> 4];
        hex[2 * idx + 1] = "0123456789abcdef"[byte & 0xf];
    }
    const root = "/usr/lib/debug/.build-id/";
    const text = hex[0 .. 2 * id.len];
    const parts = .{ root, text[0..2], text[2..] };
    return std.fmt.bufPrintZ(buffer, "{s}{s}/{s}.debug", parts) catch null;
}
