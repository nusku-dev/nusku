//! Many modules' unwind tables in one flat array, the way they will sit in BPF maps: all rows
//! in one array, and one small descriptor per module saying where its rows are. `find` is
//! written the way the BPF program must do it (fixed number of steps, no pointers), so a test
//! can check it against `compact.Table.find`.
const std = @import("std");
const compact = @import("compact.zig");

/// Where one module's rows are. Written to a BPF map as it is, so it has no padding.
pub const Module = extern struct {
    /// `Table.base`: the file address every `Row.pc` is relative to.
    base: u64,
    row_start: u32,
    row_count: u32,
    /// `Table.end`: one past the last covered address, relative to `base`.
    end: u32,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Module) == 24);
}

/// Enough for a binary search over 2^20 rows, far more than libc needs (16886).
pub const max_search_steps = 20;

pub const AddError = error{ TableFull, TooManyModules } || std.mem.Allocator.Error;

pub const TableSet = struct {
    allocator: std.mem.Allocator,
    max_rows: u32,
    max_modules: u32,
    rows: std.ArrayList(compact.Row) = .empty,
    modules: std.ArrayList(Module) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_rows: u32, max_modules: u32) TableSet {
        return .{ .allocator = allocator, .max_rows = max_rows, .max_modules = max_modules };
    }

    pub fn deinit(self: *TableSet) void {
        self.rows.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.* = undefined;
    }

    /// Appends a table and returns its module id. If it does not fit, nothing changes.
    pub fn add(self: *TableSet, table: compact.Table) AddError!u32 {
        if (self.modules.items.len >= self.max_modules) return error.TooManyModules;
        if (table.rows.len > self.max_rows - self.rows.items.len) return error.TableFull;
        try self.rows.ensureUnusedCapacity(self.allocator, table.rows.len);
        try self.modules.ensureUnusedCapacity(self.allocator, 1);

        const id: u32 = @intCast(self.modules.items.len);
        self.modules.appendAssumeCapacity(.{
            .base = table.base,
            .row_start = @intCast(self.rows.items.len),
            .row_count = @intCast(table.rows.len),
            .end = table.end,
        });
        self.rows.appendSliceAssumeCapacity(table.rows);
        return id;
    }

    /// The row that holds at `addr` (an address in the module's file), or null where no
    /// function is. The same answer as `Table.find`, found the way the BPF program will.
    pub fn find(self: TableSet, id: u32, addr: u64) ?compact.Row {
        if (id >= self.modules.items.len) return null;
        const m = self.modules.items[id];
        if (addr < m.base) return null;
        const rel = addr - m.base;
        if (rel >= m.end) return null;

        const rows = self.rows.items[m.row_start..][0..m.row_count];
        // The number of rows that start at or below the address.
        var lo: u32 = 0;
        var hi: u32 = m.row_count;
        var steps: u32 = 0;
        while (lo < hi and steps < max_search_steps) : (steps += 1) {
            const mid = lo + (hi - lo) / 2;
            if (@as(u64, rows[mid].pc) <= rel) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const newRow = rows[lo - 1];
        return if (newRow.cfa_type == @intFromEnum(compact.CfaType.none)) null else newRow;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn row(pc: u32, kind: compact.CfaType, cfa_offset: i32) compact.Row {
    return .{ .pc = pc, .cfa_offset = cfa_offset, .cfa_type = @intFromEnum(kind), .rbp_type = 0, .rbp_offset = 0 };
}

// 0x00..0x10 rsp+8, 0x10..0x20 rbp+16, 0x20..0x30 gap, 0x30..0x40 rsp+8
const rows_a = [_]compact.Row{
    row(0x00, .rsp, 8),
    row(0x10, .rbp, 16),
    row(0x20, .none, 0),
    row(0x30, .rsp, 8),
    row(0x40, .none, 0),
};
const rows_b = [_]compact.Row{
    row(0x00, .rsp, 24),
    row(0x08, .none, 0),
};

fn sameRow(a: ?compact.Row, b: ?compact.Row) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a.?), std.mem.asBytes(&b.?));
}

test "find gives the same answer as Table.find, for every address, in every module" {
    const a = compact.Table{ .base = 0x1000, .end = 0x40, .rows = &rows_a };
    const b = compact.Table{ .base = 0x5000, .end = 0x08, .rows = &rows_b };

    var set = TableSet.init(testing.allocator, 100, 10);
    defer set.deinit();
    const id_a = try set.add(a);
    const id_b = try set.add(b);
    try testing.expectEqual(@as(u32, 0), id_a);
    try testing.expectEqual(@as(u32, 1), id_b);

    var addr: u64 = 0x0ff0;
    while (addr < 0x1060) : (addr += 1) try sameRow(a.find(addr), set.find(id_a, addr));
    addr = 0x4ff0;
    while (addr < 0x5020) : (addr += 1) try sameRow(b.find(addr), set.find(id_b, addr));

    try sameRow(null, set.find(id_a, std.math.maxInt(u64)));
    try sameRow(null, set.find(7, 0x1000)); // a module id that does not exist
    try testing.expectEqual(@as(u32, 5), set.modules.items[id_b].row_start); // b's rows follow a's
}

test "an empty table is a module that finds nothing" {
    var set = TableSet.init(testing.allocator, 10, 10);
    defer set.deinit();
    const id = try set.add(.{ .base = 0, .end = 0, .rows = &.{} });
    try testing.expect(set.find(id, 0) == null);
    try testing.expect(set.find(id, 0x1000) == null);
}

test "a table that does not fit changes nothing, and the next one that fits still goes in" {
    var set = TableSet.init(testing.allocator, 6, 2);
    defer set.deinit();
    const a = compact.Table{ .base = 0x1000, .end = 0x40, .rows = &rows_a };
    const b = compact.Table{ .base = 0x5000, .end = 0x08, .rows = &rows_b };

    _ = try set.add(a); // 5 of 6 rows
    try testing.expectError(error.TableFull, set.add(b)); // needs 2
    try testing.expectEqual(@as(usize, 5), set.rows.items.len);
    try testing.expectEqual(@as(usize, 1), set.modules.items.len);

    const tiny = compact.Table{ .base = 0x9000, .end = 4, .rows = rows_b[1..] }; // 1 row
    _ = try set.add(tiny);
    try testing.expectError(error.TooManyModules, set.add(tiny));
}

test "a search over many rows needs no more steps than the limit" {
    var big: [100_000]compact.Row = undefined;
    for (&big, 0..) |*r, i| r.* = row(@intCast(i * 4), if (i % 2 == 0) .rsp else .rbp, @intCast(i % 64));
    const t = compact.Table{ .base = 0x10000, .end = 400_000, .rows = &big };

    var set = TableSet.init(testing.allocator, 200_000, 4);
    defer set.deinit();
    const id = try set.add(t);

    var addr: u64 = 0x10000 - 8;
    while (addr < 0x10000 + 400_000 + 8) : (addr += 97) try sameRow(t.find(addr), set.find(id, addr));
    try sameRow(t.find(0x10000 + 399_999), set.find(id, 0x10000 + 399_999)); // the last byte
}
