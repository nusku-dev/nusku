//! Every module's rows in one array.

const std = @import("std");
const assert = std.debug.assert;
const table = @import("table.zig");
const unwind_wire = @import("wire.zig");

const Row = table.Row;
const CfaType = table.CfaType;
pub const Module = unwind_wire.Module;

const search_steps_max = unwind_wire.row_search_steps_max;
pub const search_rows_max: u32 = (1 << search_steps_max) - 1;

comptime {
    assert(search_rows_max >= unwind_wire.rows_max);
}

pub const TableSet = struct {
    rows: []Row,
    rows_count: u32,

    modules: []Module,
    modules_count: u32,

    pub const Options = struct {
        rows_max: u32,
        modules_max: u32,
    };
    pub fn init(set: *TableSet, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.rows_max > 0);
        assert(options.rows_max <= unwind_wire.rows_max);
        assert(options.modules_max > 0);
        assert(options.modules_max <= unwind_wire.modules_max);

        const rows = try gpa.alloc(Row, options.rows_max);
        errdefer gpa.free(rows);

        const modules = try gpa.alloc(Module, options.modules_max);
        errdefer gpa.free(modules);

        @memset(rows, std.mem.zeroes(Row));
        @memset(modules, std.mem.zeroes(Module));

        set.* = .{
            .rows = rows,
            .rows_count = 0,
            .modules = modules,
            .modules_count = 0,
        };
    }

    pub fn add(set: *TableSet, module_table: *const table.Table) !u32 {
        assert(set.rows_count <= set.rows.len);
        assert(set.modules_count <= set.modules.len);
        table_assert_valid(module_table);

        if (module_table.rows.len > search_rows_max) return error.TableTooLarge;
        if (set.modules_count == set.modules.len) return error.TooManyModules;
        if (module_table.rows.len > set.rows.len - set.rows_count) return error.TableFull;
        const module_id = set.modules_count;

        const row_start = set.rows_count;
        const row_count: u32 = @intCast(module_table.rows.len);

        @memcpy(set.rows[row_start..][0..row_count], module_table.rows);
        set.modules[module_id] = .{
            .base = module_table.base,
            .row_start = row_start,
            .row_count = row_count,
            .end = module_table.end,
        };
        set.rows_count += row_count;
        set.modules_count += 1;

        assert(set.rows_count == row_start + row_count);
        assert(set.modules_count == module_id + 1);
        return module_id;
    }

    pub fn find(set: *const TableSet, module_id: u32, address: u64) ?Row {
        if (module_id >= set.modules_count) return null;
        const module = set.modules[module_id];
        assert(module.reserved == 0);

        assert(@as(u64, module.row_start) + module.row_count <= set.rows_count);

        if (address < module.base) return null;
        const pc_relative = address - module.base;
        if (pc_relative >= module.end) return null;

        const rows = set.rows[module.row_start..][0..module.row_count];
        const count = search(rows, pc_relative);
        if (count == 0) return null;

        const row = rows[count - 1];
        assert(row.pc <= pc_relative);
        if (row.cfa_type == @intFromEnum(CfaType.none)) return null;
        return row;
    }

    pub fn deinit(set: *TableSet, gpa: std.mem.Allocator) void {
        gpa.free(set.rows);
        gpa.free(set.modules);
        set.* = undefined;
    }
};

fn table_assert_valid(module_table: *const table.Table) void {
    for (module_table.rows, 0..) |row, index| {
        assert(row.pc <= module_table.end);
        if (row.pc == module_table.end) assert(row.cfa_type == @intFromEnum(CfaType.none));
        if (index > 0) assert(module_table.rows[index - 1].pc < row.pc);
    }
}

fn search(rows: []const Row, pc_relative: u64) u32 {
    assert(rows.len <= search_rows_max);

    var low: u32 = 0;
    var high: u32 = @intCast(rows.len);
    var steps: u32 = 0;
    while (steps < search_steps_max) : (steps += 1) {
        if (low < high) {
            const middle = low + @divFloor(high - low, 2);
            if (rows[middle].pc <= pc_relative) {
                low = middle + 1;
            } else {
                high = middle;
            }
        } else {
            break;
        }
    }
    assert(low == high);
    assert(low <= rows.len);
    return low;
}

const testing = std.testing;

fn row_for_test(pc: u32, kind: CfaType, cfa_offset: i32) Row {
    return .{
        .pc = pc,
        .cfa_offset = cfa_offset,
        .cfa_type = @intFromEnum(kind),
        .rbp_type = 0,
        .rbp_offset = 0,
    };
}

const rows_a = [_]Row{
    row_for_test(0x00, .rsp, 8),
    row_for_test(0x10, .rbp, 16),
    row_for_test(0x20, .none, 0),
    row_for_test(0x30, .rsp, 8),
    row_for_test(0x40, .none, 0),
};
const rows_b = [_]Row{
    row_for_test(0x00, .rsp, 24),
    row_for_test(0x08, .none, 0),
};

fn rows_expect_equal(a: ?Row, b: ?Row) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a.?), std.mem.asBytes(&b.?));
}

test "find gives the same answer as Table.find, for every address, in every module" {
    const a = table.Table{ .base = 0x1000, .end = 0x40, .rows = &rows_a };
    const b = table.Table{ .base = 0x5000, .end = 0x08, .rows = &rows_b };

    var set: TableSet = undefined;
    try set.init(testing.allocator, .{ .rows_max = 100, .modules_max = 10 });
    defer set.deinit(testing.allocator);

    const id_a = try set.add(&a);
    const id_b = try set.add(&b);
    try testing.expectEqual(@as(u32, 0), id_a);
    try testing.expectEqual(@as(u32, 1), id_b);

    var addr: u64 = 0x0ff0;
    while (addr < 0x1060) : (addr += 1) try rows_expect_equal(a.find(addr), set.find(id_a, addr));
    addr = 0x4ff0;
    while (addr < 0x5020) : (addr += 1) try rows_expect_equal(b.find(addr), set.find(id_b, addr));

    try rows_expect_equal(null, set.find(id_a, std.math.maxInt(u64)));
    try rows_expect_equal(null, set.find(7, 0x1000));
    try testing.expectEqual(@as(u32, 5), set.modules[id_b].row_start);
}

test "an empty table is a module that finds nothing" {
    var set: TableSet = undefined;
    try set.init(testing.allocator, .{ .rows_max = 10, .modules_max = 10 });
    defer set.deinit(testing.allocator);

    const empty = table.Table{ .base = 0, .end = 0, .rows = &.{} };
    const id = try set.add(&empty);
    try testing.expect(set.find(id, 0) == null);
    try testing.expect(set.find(id, 0x1000) == null);
}

test "a table that does not fit changes nothing, and the next one that fits still goes in" {
    var set: TableSet = undefined;
    try set.init(testing.allocator, .{ .rows_max = 6, .modules_max = 2 });
    defer set.deinit(testing.allocator);

    const a = table.Table{ .base = 0x1000, .end = 0x40, .rows = &rows_a };
    const b = table.Table{ .base = 0x5000, .end = 0x08, .rows = &rows_b };

    _ = try set.add(&a);
    try testing.expectError(error.TableFull, set.add(&b));
    try testing.expectEqual(@as(u32, 5), set.rows_count);
    try testing.expectEqual(@as(u32, 1), set.modules_count);

    const tiny = table.Table{ .base = 0x9000, .end = 0x08, .rows = rows_b[1..] };
    _ = try set.add(&tiny);
    try testing.expectError(error.TooManyModules, set.add(&tiny));
}

test "a search over many rows needs no more steps than the limit" {
    var big: [100_000]Row = undefined;
    for (&big, 0..) |*r, i| {
        r.* = row_for_test(@intCast(i * 4), if (i % 2 == 0) .rsp else .rbp, @intCast(i % 64));
    }
    const big_table = table.Table{ .base = 0x10000, .end = 400_000, .rows = &big };

    var set: TableSet = undefined;
    try set.init(testing.allocator, .{ .rows_max = 200_000, .modules_max = 4 });
    defer set.deinit(testing.allocator);

    const id = try set.add(&big_table);

    var addr: u64 = 0x10000 - 8;
    while (addr < 0x10000 + 400_000 + 8) : (addr += 97) {
        try rows_expect_equal(big_table.find(addr), set.find(id, addr));
    }
    const address_last = 0x10000 + 399_999;
    try rows_expect_equal(big_table.find(address_last), set.find(id, address_last));
}
