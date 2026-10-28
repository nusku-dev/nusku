const std = @import("std");
const cfi = @import("core/cfi.zig");
const ehframe = @import("core/ehframe.zig");
const mech = @import("machine.zig");
const assert = std.debug.assert;

const Machine = mech.Machine;
const Program = mech.Program;

/// The return address is always at CFA-8 in a supported row; the CFA of the caller is the CFA.
pub const Row = extern struct {
    /// Where the range starts, relative to `Table.base`.
    pc: u32,
    cfa_offset: i32,
    cfa_type: u8,
    rbp_type: u8,
    rbp_offset: i16,
};

comptime {
    std.debug.assert(@sizeOf(Row) == 12);
}

pub const CfaType = enum(u8) {
    /// No function covers the range: a gap between functions.
    none = 0,
    /// The rules of the range cannot be written in this format.
    unsupported = 1,
    /// CFA = rsp + offset
    rsp = 2,
    /// CFA = rbp + offset
    rbp = 3,
    /// The CFA of a PLT stub: rsp + 8, plus 8 if (rip % 16) >= offset. The offset holds the threshold.
    plt = 4,
    /// The return address is undefined: the outermost frame.
    end = 5,
};

pub const RbpType = enum(u8) {
    /// rbp has the same value in the caller.
    same = 0,
    /// rbp is saved in memory at CFA + rbp_offset.
    saved = 1,
};

const unsupported_row = Row{
    .pc = 0,
    .cfa_offset = 0,
    .cfa_type = @intFromEnum(CfaType.unsupported),
    .rbp_type = 0,
    .rbp_offset = 0,
};

const gap_row = Row{
    .pc = 0,
    .cfa_offset = 0,
    .cfa_type = @intFromEnum(CfaType.none),
    .rbp_type = 0,
    .rbp_offset = 0,
};

const end_row = Row{
    .pc = 0,
    .cfa_offset = 0,
    .cfa_type = @intFromEnum(CfaType.end),
    .rbp_type = 0,
    .rbp_offset = 0,
};

/// One row of full rules in the compact form, with `pc` left at 0.
pub fn convert(row: cfi.Row) Row {
    switch (row.rules[cfi.reg_ra]) {
        .undef => return end_row,
        .offset => |offset| if (offset != -8) return unsupported_row,
        else => return unsupported_row,
    }
    // The stack pointer of the caller is the CFA by definition. A rule that says otherwise
    // is not handled.
    switch (row.rules[cfi.reg_rsp]) {
        .unspecified => {},
        else => return unsupported_row,
    }

    var out = Row{
        .pc = 0,
        .cfa_offset = 0,
        .cfa_type = @intFromEnum(CfaType.none),
        .rbp_type = @intFromEnum(RbpType.same),
        .rbp_offset = 0,
    };
    switch (row.rules[cfi.reg_rbp]) {
        .unspecified, .same => {},
        .offset => |offset| {
            out.rbp_type = @intFromEnum(RbpType.saved);
            out.rbp_offset = std.math.cast(i16, offset) orelse return unsupported_row;
        },
        else => return unsupported_row,
    }

    switch (row.cfa) {
        .unset => return unsupported_row,
        .register => |cfa| {
            const cfa_type = cfa_type_from_register(cfa.reg) orelse return unsupported_row;
            out.cfa_type = @intFromEnum(cfa_type);
            out.cfa_offset = std.math.cast(i32, cfa.offset) orelse return unsupported_row;
        },
        .expression => |expression| {
            out.cfa_type = @intFromEnum(CfaType.plt);
            out.cfa_offset = plt_threshold(expression) orelse return unsupported_row;
        },
    }
    // Every path that reaches here set a CFA rule.
    assert(out.cfa_type != @intFromEnum(CfaType.none));
    return out;
}

/// Pure: says which CFA type a register means, and leaves the decision to the caller.
fn cfa_type_from_register(register: u64) ?CfaType {
    return switch (register) {
        cfi.reg_rsp => .rsp,
        cfi.reg_rbp => .rbp,
        else => null,
    };
}
/// The expression compilers write for the CFA of a PLT stub:
///   rsp + 8 + ((rip & 15) >= T ? 8 : 0)
/// Returns T, or null for any other expression.
fn plt_threshold(e: []const u8) ?i32 {
    const prefix = [_]u8{ 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a };
    const suffix = [_]u8{ 0x2a, 0x33, 0x24, 0x22 };
    if (e.len != prefix.len + 1 + suffix.len) return null;
    if (!std.mem.eql(u8, e[0..prefix.len], &prefix)) return null;
    if (!std.mem.eql(u8, e[prefix.len + 1 ..], &suffix)) return null;
    const lit = e[prefix.len];
    if (lit < 0x30 or lit > 0x4f) return null;
    return @as(i32, lit - 0x30);
}

const Pending = struct { rel: u64, content: Row };

pub const Table = struct {
    /// The address in the file that every `Row.pc` is relative to: where the first function begins.
    base: u64,
    /// One past the last covered address, relative to `base`.
    end: u32,
    /// Sorted by `pc`. Gaps between functions are rows of type `none`.
    rows: []const Row,

    pub fn init(table: *Table, gpa: std.mem.Allocator, fdes: []const ehframe.Fde) !void {
        if (fdes.len == 0) {
            table.* = .{
                .base = 0,
                .end = 0,
                .rows = &.{},
            };
            return;
        }
        const base = fdes[0].pc_begin;

        var rows: std.ArrayList(Row) = .empty;
        errdefer rows.deinit(gpa);
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(gpa);

        var cursor = base;
        for (fdes) |fde| {
            if (fde.pc_begin < cursor) return error.Overlap;
            if (fde.pc_end <= fde.pc_begin) continue;
            if (fde.pc_begin > cursor) try push(gpa, &rows, cursor - base, gap_row);

            pending.clearRetainingCapacity();
            if (try readRows(gpa, fde, &pending, base)) {
                for (pending.items) |p| try push(gpa, &rows, p.rel, p.content);
            } else {
                try push(gpa, &rows, fde.pc_begin - base, unsupported_row);
            }
            cursor = fde.pc_end;
        }
        try push(gpa, &rows, cursor - base, gap_row);
        const end = std.math.cast(u32, cursor - base) orelse return error.TooLarge;

        table.* = .{
            .base = base,
            .end = end,
            .rows = try rows.toOwnedSlice(gpa),
        };
    }

    fn push(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), rel: u64, content: Row) !void {
        const pc = std.math.cast(u32, rel) orelse return error.TooLarge;
        if (rows.items.len > 0 and sameRules(rows.items[rows.items.len - 1], content)) return;
        var row = content;
        row.pc = pc;
        try rows.append(gpa, row);
    }

    fn sameRules(a: Row, b: Row) bool {
        return a.cfa_offset == b.cfa_offset and a.cfa_type == b.cfa_type and
            a.rbp_type == b.rbp_type and a.rbp_offset == b.rbp_offset;
    }

    fn readRows(gpa: std.mem.Allocator, fde: ehframe.Fde, out: *std.ArrayList(Pending), base: u64) std.mem.Allocator.Error!bool {
        if (fde.cie.signal_frame) return false;
        var it: RowIterator = undefined;

        it.init(fde) catch return false;
        while (true) {
            const next = it.next() catch return false;
            const entry = next orelse return true;
            try out.append(gpa, .{ .rel = entry.start - base, .content = convert(entry.row) });
        }
    }

    pub fn deinit(table: *Table, allocator: std.mem.Allocator) void {
        allocator.free(table.rows);
        table.* = undefined;
    }

    pub fn find(table: Table, addr: u64) ?Row {
        if (addr < table.base) return null;
        const rel = addr - table.base;

        if (rel >= table.end) return null;

        var lo: usize = 0;
        var hi: usize = table.rows.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (table.rows[mid].pc <= rel) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) return null;
        const row = table.rows[lo - 1];

        if (row.cfa_type == @intFromEnum(CfaType.none)) return null;

        return row;
    }

    pub fn count(table: Table, kind: CfaType) usize {
        var n: usize = 0;
        for (table.rows) |r| {
            if (r.cfa_type == @intFromEnum(kind)) n += 1;
        }
        return n;
    }
};

/// The rule row that holds for the addresses start <= pc < end.
const Entry = struct {
    start: u64,
    end: u64,
    row: cfi.Row,
};

pub const RowIterator = struct {
    machine: Machine,
    program: Program,
    pc_end: u64,
    done: bool = false,

    pub fn init(row_iterator: *RowIterator, fde: ehframe.Fde) !void {
        const m = try Machine.init(fde);
        row_iterator.* = .{
            .machine = m,
            .program = Program{
                .bytes = fde.instructions,
            },
            .pc_end = fde.pc_end,
        };
    }

    pub fn next(self: *RowIterator) !?Entry {
        while (!self.done) {
            const start = self.machine.loc;
            const advance = try self.machine.runToAdvance(&self.program);

            var end = self.pc_end;
            if (advance) |to| {
                if (to < self.pc_end) end = to else self.done = true; // the last row reaches the end
            } else {
                self.done = true;
            }
            const row = self.machine.row;
            self.machine.loc = end;
            if (end > start) return Entry{ .start = start, .end = end, .row = row };
        }
        return null;
    }
};
