//! DWARF line tables: which file and line each address came from.
const std = @import("std");
const reader = @import("reader.zig");
const decoder = @import("decoder.zig");

const Reader = reader.Reader;
const Error = reader.Error;

pub const Row = struct {
    address: u64,
    file: u32,
    line: u32,
    end: bool,
};

pub const Sections = struct {
    line: []const u8,
    line_str: []const u8,
    str: []const u8,
};

/// Where a unit's files sit in the shared list; `base` is the index its first file has.
pub const Files = struct {
    first: u32,
    count: u32,
    base: u8,

    pub fn global(files: Files, index: u64) ?u32 {
        if (index < files.base) return null;
        const local = index - files.base;
        if (local >= files.count) return null;
        return files.first + @as(u32, @intCast(local));
    }
};

pub const Output = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    rows: *std.ArrayList(Row),
};

pub fn program_read(
    sections: Sections,
    at: u64,
    comp_dir: []const u8,
    address_size: u8,
    out: Output,
) Error!Files {
    if (at >= sections.line.len) return error.Malformed;
    var r: Reader = undefined;
    r.init(sections.line, @intCast(at));
    var wide = false;
    const length = try r.length(&wide);
    const end = std.math.add(u64, r.at, length) catch return error.Malformed;
    if (end > sections.line.len) return error.Malformed;
    r.bytes = sections.line[0..@intCast(end)];

    const version = try r.int(u16);
    if (version < 2 or version > 5) return error.Malformed;
    var unit = decoder.Unit{ .version = version, .wide = wide, .address_size = address_size };
    if (version >= 5) {
        unit.address_size = try r.int(u8);
        _ = try r.int(u8);
    }
    const header_length = try r.offset(wide);
    const program_at = std.math.add(u64, r.at, header_length) catch return error.Malformed;
    if (program_at > r.bytes.len) return error.Malformed;

    const rules = Rules{
        .min_inst = try r.int(u8),
        .max_ops = if (version >= 4) try r.int(u8) else 1,
        .default_stmt = try r.int(u8) != 0,
        .line_base = try r.int(i8),
        .line_range = try r.int(u8),
        .opcode_base = try r.int(u8),
        .lengths = undefined,
    };
    if (rules.line_range == 0 or rules.opcode_base == 0) return error.Malformed;
    var lengths: [256]u8 = @splat(0);
    for (1..rules.opcode_base) |op| lengths[op] = try r.int(u8);

    const files = if (version >= 5)
        try files_v5(&r, sections, unit, comp_dir, out)
    else
        try files_v4(&r, comp_dir, out);

    r.at = @intCast(program_at);
    var with = rules;
    with.lengths = &lengths;
    try rows_read(&r, with, files, out);
    return files;
}

/// Rows sorted by address; the row that covers `address`, if any.
pub fn row_find(rows: []const Row, address: u64) ?*const Row {
    var low: usize = 0;
    var high: usize = rows.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (rows[middle].address <= address) low = middle + 1 else high = middle;
    }
    if (low == 0) return null;
    var index = low - 1;
    const at = rows[index].address;
    while (rows[index].end and index > 0 and rows[index - 1].address == at) index -= 1;
    const row = &rows[index];
    if (row.end) return null;
    return row;
}

pub fn row_less(_: void, a: Row, b: Row) bool {
    if (a.address != b.address) return a.address < b.address;
    return @intFromBool(a.end) > @intFromBool(b.end);
}

const Rules = struct {
    min_inst: u8,
    max_ops: u8,
    default_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    lengths: *const [256]u8,
};

fn files_v4(r: *Reader, comp_dir: []const u8, out: Output) Error!Files {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(out.gpa);
    try dirs.append(out.gpa, comp_dir);
    while (true) {
        const dir = try r.string();
        if (dir.len == 0) break;
        try dirs.append(out.gpa, dir);
    }
    const first: u32 = @intCast(out.files.items.len);
    while (true) {
        const name = try r.string();
        if (name.len == 0) break;
        const dir = try r.uleb();
        _ = try r.uleb();
        _ = try r.uleb();
        const in = if (dir < dirs.items.len) dirs.items[@intCast(dir)] else "";
        try out.files.append(out.gpa, try path_join(out.arena, comp_dir, in, name));
    }
    return .{ .first = first, .count = @intCast(out.files.items.len - first), .base = 1 };
}

const Entry = struct { kind: u64, form: u64 };

fn files_v5(
    r: *Reader,
    sections: Sections,
    unit: decoder.Unit,
    comp_dir: []const u8,
    out: Output,
) Error!Files {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(out.gpa);
    var formats: [16]Entry = undefined;

    const dir_formats = try formats_read(r, &formats);
    const dir_count = try r.uleb();
    for (0..@intCast(dir_count)) |_| {
        var path: []const u8 = "";
        for (dir_formats) |format| {
            const value = try decoder.value_read(r, format.form, 0, unit);
            if (format.kind == lnct_path) path = string_of(sections, value) orelse "";
        }
        try dirs.append(out.gpa, path);
    }

    const file_formats = try formats_read(r, &formats);
    const file_count = try r.uleb();
    const first: u32 = @intCast(out.files.items.len);
    for (0..@intCast(file_count)) |_| {
        var path: []const u8 = "";
        var dir: u64 = 0;
        for (file_formats) |format| {
            const value = try decoder.value_read(r, format.form, 0, unit);
            switch (format.kind) {
                lnct_path => path = string_of(sections, value) orelse "",
                lnct_directory_index => dir = value.number() orelse 0,
                else => {},
            }
        }
        const home = if (dirs.items.len > 0) dirs.items[0] else comp_dir;
        const in = if (dir > 0 and dir < dirs.items.len) dirs.items[@intCast(dir)] else "";
        try out.files.append(out.gpa, try path_join(out.arena, home, in, path));
    }
    return .{ .first = first, .count = @intCast(out.files.items.len - first), .base = 0 };
}

fn formats_read(r: *Reader, buffer: *[16]Entry) Error![]const Entry {
    const count = try r.int(u8);
    if (count > buffer.len) return error.Malformed;
    for (buffer[0..count]) |*entry| entry.* = .{ .kind = try r.uleb(), .form = try r.uleb() };
    return buffer[0..count];
}

fn string_of(sections: Sections, value: decoder.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        .line_strp => |at| decoder.string_at(sections.line_str, at),
        .strp => |at| decoder.string_at(sections.str, at),
        else => null,
    };
}

fn path_join(
    arena: std.mem.Allocator,
    comp_dir: []const u8,
    dir: []const u8,
    name: []const u8,
) Error![]const u8 {
    if (std.fs.path.isAbsolute(name)) return arena.dupe(u8, name);
    if (dir.len == 0) return std.fs.path.join(arena, &.{ comp_dir, name });
    if (std.fs.path.isAbsolute(dir)) return std.fs.path.join(arena, &.{ dir, name });
    return std.fs.path.join(arena, &.{ comp_dir, dir, name });
}

const lnct_path = 1;
const lnct_directory_index = 2;

const State = struct {
    address: u64 = 0,
    file: u64 = 1,
    line: i64 = 1,
};

fn rows_read(r: *Reader, rules: Rules, files: Files, out: Output) Error!void {
    var state = State{};
    while (!r.done()) {
        const op = try r.int(u8);
        if (op >= rules.opcode_base) {
            const adjusted = op - rules.opcode_base;
            state.address +%= @as(u64, adjusted / rules.line_range) * rules.min_inst;
            state.line += rules.line_base + @as(i64, adjusted % rules.line_range);
            try row_add(out, files, state, false);
            continue;
        }
        switch (op) {
            0 => {
                const size = try r.uleb();
                if (size == 0) continue;
                const sub_at = r.at;
                const sub = try r.int(u8);
                switch (sub) {
                    1 => {
                        try row_add(out, files, state, true);
                        state = .{};
                    },
                    2 => state.address = try r.sized(@intCast(@min(size - 1, 8))),
                    else => {},
                }
                r.at = sub_at;
                _ = try r.take(size);
            },
            1 => try row_add(out, files, state, false),
            2 => state.address +%= (try r.uleb()) * rules.min_inst,
            3 => state.line += try r.sleb(),
            4 => state.file = try r.uleb(),
            8 => {
                const advance = (255 - rules.opcode_base) / rules.line_range;
                state.address +%= @as(u64, advance) * rules.min_inst;
            },
            9 => state.address +%= try r.int(u16),
            else => for (0..rules.lengths[op]) |_| {
                _ = try r.uleb();
            },
        }
    }
}

fn row_add(out: Output, files: Files, state: State, end: bool) Error!void {
    const fits = state.line > 0 and state.line <= std.math.maxInt(u32);
    const line: u32 = if (fits) @intCast(state.line) else 0;
    try out.rows.append(out.gpa, .{
        .address = state.address,
        .file = files.global(state.file) orelse std.math.maxInt(u32),
        .line = line,
        .end = end,
    });
}

const testing = std.testing;

test "a row covers addresses up to the next one, and nothing past the end of its sequence" {
    const rows = [_]Row{
        .{ .address = 0x100, .file = 0, .line = 10, .end = false },
        .{ .address = 0x110, .file = 0, .line = 12, .end = false },
        .{ .address = 0x120, .file = 0, .line = 0, .end = true },
        .{ .address = 0x200, .file = 1, .line = 3, .end = false },
        .{ .address = 0x210, .file = 1, .line = 0, .end = true },
    };
    try testing.expect(row_find(&rows, 0xff) == null);
    try testing.expectEqual(@as(u32, 10), row_find(&rows, 0x100).?.line);
    try testing.expectEqual(@as(u32, 10), row_find(&rows, 0x10f).?.line);
    try testing.expectEqual(@as(u32, 12), row_find(&rows, 0x11f).?.line);
    try testing.expect(row_find(&rows, 0x120) == null);
    try testing.expect(row_find(&rows, 0x1ff) == null);
    try testing.expectEqual(@as(u32, 3), row_find(&rows, 0x200).?.line);
}

test "a sequence that ends where the next starts gives the next" {
    var rows = [_]Row{
        .{ .address = 0x100, .file = 0, .line = 1, .end = false },
        .{ .address = 0x200, .file = 0, .line = 7, .end = false },
        .{ .address = 0x200, .file = 0, .line = 0, .end = true },
    };
    std.mem.sort(Row, &rows, {}, row_less);
    try testing.expectEqual(@as(u32, 7), row_find(&rows, 0x200).?.line);
}
