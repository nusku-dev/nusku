//! One binary's unwind table in the compact form the kernel program reads: rows sorted by
//! address, each saying how to find the caller's frame from anywhere in its range.
//!
//! The rows come from running each FDE's DWARF CFI program (cfi_machine.zig) and keeping only
//! what an x86-64 walk needs: the CFA rule, and where rbp is saved. Rules the kernel program
//! cannot apply become `unsupported` rows, so the walk stops there with a reason instead of
//! guessing.

const std = @import("std");
const assert = std.debug.assert;
const cfi = @import("cfi.zig");
const eh_frame = @import("eh_frame.zig");
const cfi_machine = @import("cfi_machine.zig");
const go_pclntab = @import("go_pclntab.zig");
const unwind_wire = @import("../bpf/kernel/shared/unwind_wire.zig");

const Machine = cfi_machine.Machine;
const Program = cfi_machine.Program;

pub const Row = unwind_wire.Row;
pub const CfaType = unwind_wire.CfaType;
pub const RbpType = unwind_wire.RbpType;

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
pub fn row_compact(row: cfi.Row) Row {
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

/// A row whose address is not yet relative to the table base.
const Pending = struct { relative: u64, content: Row };

pub const Table = struct {
    /// The address in the file that every `Row.pc` is relative to: where the first function begins.
    base: u64,
    /// One past the last covered address, relative to `base`.
    end: u32,
    /// Sorted by `pc`. Gaps between functions are rows of type `none`.
    rows: []const Row,

    pub fn init(table: *Table, gpa: std.mem.Allocator, fdes: []const eh_frame.Fde) !void {
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
            if (try rows_read(gpa, fde, &pending, base)) {
                for (pending.items) |item| try push(gpa, &rows, item.relative, item.content);
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

    /// The table of a Go binary, from its pclntab (see go_pclntab.zig) instead of .eh_frame.
    pub fn init_go(
        table: *Table,
        gpa: std.mem.Allocator,
        pclntab: *const go_pclntab.Pclntab,
    ) !void {
        if (pclntab.function_count == 0) {
            table.* = .{ .base = 0, .end = 0, .rows = &.{} };
            return;
        }
        const base = (try pclntab.function(0)).entry;

        var rows: std.ArrayList(Row) = .empty;
        errdefer rows.deinit(gpa);

        var cursor = base;
        var index: u32 = 0;
        while (index < pclntab.function_count) : (index += 1) {
            const function = try pclntab.function(index);
            if (function.entry < cursor) return error.Overlap;
            if (function.entry > cursor) try push(gpa, &rows, cursor - base, gap_row);
            cursor = try go_function_push(gpa, &rows, base, &function);
        }
        try push(gpa, &rows, cursor - base, gap_row);
        const end = std.math.cast(u32, cursor - base) orelse return error.TooLarge;

        table.* = .{
            .base = base,
            .end = end,
            .rows = try rows.toOwnedSlice(gpa),
        };
    }

    /// Pushes the rows of one Go function, and returns where they end.
    fn go_function_push(
        gpa: std.mem.Allocator,
        rows: *std.ArrayList(Row),
        base: u64,
        function: *const go_pclntab.Function,
    ) !u64 {
        assert(function.entry >= base);
        if (function.flag & go_pclntab.flag_top_frame != 0) {
            try push(gpa, rows, function.entry - base, end_row);
            return function.next_entry;
        }
        // Without a pcsp table nothing says where the frame is; writing SP itself, the table
        // cannot say it.
        const sp_unknown = function.pcsp.len == 0;
        if (sp_unknown or function.flag & go_pclntab.flag_sp_write != 0) {
            try push(gpa, rows, function.entry - base, unsupported_row);
            return function.next_entry;
        }

        var iterator = go_pclntab.PcspIterator{ .bytes = function.pcsp, .pc = function.entry };
        var end = function.entry;
        while (try iterator.next()) |range| {
            if (range.end > function.next_entry) return error.Overlap;
            // A pc delta of 0 makes an empty range: it holds for no instruction.
            if (range.end == range.start) continue;
            try push(gpa, rows, range.start - base, row_go(range.sp_delta));
            end = range.end;
        }
        return end;
    }

    /// The row of a Go instruction `sp_delta` bytes below its function's entry stack pointer.
    /// Go's prologue pushes rbp first (Go 1.21 and later), so once the frame has a word, the
    /// caller's rbp is at CFA - 16. (Go 1.18 to 1.20 saved it one instruction later: for that
    /// one instruction the recovered rbp is wrong, which only matters to a frame-pointer walk
    /// further up.)
    fn row_go(sp_delta: i32) Row {
        if (sp_delta < 0) return unsupported_row;
        const cfa_offset = std.math.add(i32, sp_delta, 8) catch return unsupported_row;
        var row = Row{
            .pc = 0,
            .cfa_offset = cfa_offset,
            .cfa_type = @intFromEnum(CfaType.rsp),
            .rbp_type = @intFromEnum(RbpType.same),
            .rbp_offset = 0,
        };
        if (sp_delta >= 8) {
            row.rbp_type = @intFromEnum(RbpType.saved);
            row.rbp_offset = -16;
        }
        return row;
    }

    fn push(gpa: std.mem.Allocator, rows: *std.ArrayList(Row), relative: u64, content: Row) !void {
        const pc = std.math.cast(u32, relative) orelse return error.TooLarge;
        if (rows.items.len > 0 and rules_equal(rows.items[rows.items.len - 1], content)) return;
        var row = content;
        row.pc = pc;
        try rows.append(gpa, row);
    }

    fn rules_equal(a: Row, b: Row) bool {
        return a.cfa_offset == b.cfa_offset and a.cfa_type == b.cfa_type and
            a.rbp_type == b.rbp_type and a.rbp_offset == b.rbp_offset;
    }

    fn rows_read(
        gpa: std.mem.Allocator,
        fde: eh_frame.Fde,
        out: *std.ArrayList(Pending),
        base: u64,
    ) std.mem.Allocator.Error!bool {
        if (fde.cie.signal_frame) return false;
        var iterator: RowIterator = undefined;

        iterator.init(fde) catch return false;
        while (true) {
            const next = iterator.next() catch return false;
            const entry = next orelse return true;
            try out.append(gpa, .{
                .relative = entry.start - base,
                .content = row_compact(entry.row),
            });
        }
    }

    pub fn deinit(table: *Table, gpa: std.mem.Allocator) void {
        gpa.free(table.rows);
        table.* = undefined;
    }

    /// The row that holds at `address`, an address in the file, or null where no function is.
    /// The plain search: table_set.zig searches the way the kernel program must, and its tests
    /// compare the two.
    pub fn find(table: *const Table, address: u64) ?Row {
        if (address < table.base) return null;
        const relative = address - table.base;

        if (relative >= table.end) return null;

        var lo: usize = 0;
        var hi: usize = table.rows.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (table.rows[mid].pc <= relative) {
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

    pub fn init(row_iterator: *RowIterator, fde: eh_frame.Fde) !void {
        const machine = try Machine.init(fde);
        row_iterator.* = .{
            .machine = machine,
            .program = Program{
                .bytes = fde.instructions,
            },
            .pc_end = fde.pc_end,
        };
    }

    pub fn next(self: *RowIterator) !?Entry {
        while (!self.done) {
            const start = self.machine.loc;
            const advance = try self.machine.run_to_advance(&self.program);

            var end = self.pc_end;
            if (advance) |to| {
                // The last row reaches the end.
                if (to < self.pc_end) end = to else self.done = true;
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
