//! A compact form of the unwind rules, made to be loaded into BPF maps: a sorted array of fixed
//! size rows, one per range of addresses, holding only the rules x86-64 code actually uses.
//! Everything else becomes an "unsupported" row, so a walk that reaches it stops and says so
//! instead of guessing. `unwind` below does with a row exactly what the BPF program will do.
const std = @import("std");
const cfi = @import("cfi.zig");
const ehframe = @import("ehframe.zig");
const frame = @import("frame.zig");

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

const unsupported_row = Row{ .pc = 0, .cfa_offset = 0, .cfa_type = @intFromEnum(CfaType.unsupported), .rbp_type = 0, .rbp_offset = 0 };
const gap_row = Row{ .pc = 0, .cfa_offset = 0, .cfa_type = @intFromEnum(CfaType.none), .rbp_type = 0, .rbp_offset = 0 };
const end_row = Row{ .pc = 0, .cfa_offset = 0, .cfa_type = @intFromEnum(CfaType.end), .rbp_type = 0, .rbp_offset = 0 };

fn cfaKind(byte: u8) ?CfaType {
    return switch (byte) {
        0 => .none,
        1 => .unsupported,
        2 => .rsp,
        3 => .rbp,
        4 => .plt,
        5 => .end,
        else => null,
    };
}

fn rbpKind(byte: u8) ?RbpType {
    return switch (byte) {
        0 => .same,
        1 => .saved,
        else => null,
    };
}

/// The expression compilers write for the CFA of a PLT stub:
///   rsp + 8 + ((rip & 15) >= T ? 8 : 0)
/// Returns T, or null for any other expression.
fn pltThreshold(e: []const u8) ?i32 {
    const prefix = [_]u8{ 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a };
    const suffix = [_]u8{ 0x2a, 0x33, 0x24, 0x22 };
    if (e.len != prefix.len + 1 + suffix.len) return null;
    if (!std.mem.eql(u8, e[0..prefix.len], &prefix)) return null;
    if (!std.mem.eql(u8, e[prefix.len + 1 ..], &suffix)) return null;
    const lit = e[prefix.len];
    if (lit < 0x30 or lit > 0x4f) return null;
    return @as(i32, lit - 0x30);
}

/// One row of full rules in the compact form, with `pc` left at 0.
pub fn convert(row: cfi.Row) Row {
    switch (row.rules[cfi.reg_ra]) {
        .undef => return end_row,
        .offset => |n| if (n != -8) return unsupported_row,
        else => return unsupported_row,
    }
    // The stack pointer of the caller is the CFA by definition; a rule that says otherwise is not handled.
    switch (row.rules[cfi.reg_rsp]) {
        .unspecified => {},
        else => return unsupported_row,
    }

    var out = Row{ .pc = 0, .cfa_offset = 0, .cfa_type = 0, .rbp_type = @intFromEnum(RbpType.same), .rbp_offset = 0 };
    switch (row.rules[cfi.reg_rbp]) {
        .unspecified, .same => {},
        .offset => |n| {
            out.rbp_type = @intFromEnum(RbpType.saved);
            out.rbp_offset = std.math.cast(i16, n) orelse return unsupported_row;
        },
        else => return unsupported_row,
    }

    switch (row.cfa) {
        .unset => return unsupported_row,
        .register => |c| {
            out.cfa_offset = std.math.cast(i32, c.offset) orelse return unsupported_row;
            out.cfa_type = switch (c.reg) {
                cfi.reg_rsp => @intFromEnum(CfaType.rsp),
                cfi.reg_rbp => @intFromEnum(CfaType.rbp),
                else => return unsupported_row,
            };
        },
        .expression => |e| {
            out.cfa_offset = pltThreshold(e) orelse return unsupported_row;
            out.cfa_type = @intFromEnum(CfaType.plt);
        },
    }
    return out;
}

fn sameRules(a: Row, b: Row) bool {
    return a.cfa_offset == b.cfa_offset and a.cfa_type == b.cfa_type and
        a.rbp_type == b.rbp_type and a.rbp_offset == b.rbp_offset;
}

pub const Table = struct {
    /// The address in the file that every `Row.pc` is relative to: where the first function begins.
    base: u64,
    /// One past the last covered address, relative to `base`.
    end: u32,
    /// Sorted by `pc`. Gaps between functions are rows of type `none`.
    rows: []const Row,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        self.* = undefined;
    }

    /// The row that holds at `addr` (an address in the file), or null where no function is.
    pub fn find(self: Table, addr: u64) ?Row {
        if (addr < self.base) return null;
        const rel = addr - self.base;
        if (rel >= self.end) return null;

        // The number of rows that start at or below the address.
        var lo: usize = 0;
        var hi: usize = self.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rows[mid].pc <= rel) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const row = self.rows[lo - 1];
        return if (row.cfa_type == @intFromEnum(CfaType.none)) null else row;
    }

    pub fn count(self: Table, kind: CfaType) usize {
        var n: usize = 0;
        for (self.rows) |r| {
            if (r.cfa_type == @intFromEnum(kind)) n += 1;
        }
        return n;
    }
};

pub const BuildError = error{ Overlap, TooLarge } || std.mem.Allocator.Error;

const Pending = struct { rel: u64, content: Row };

/// `fdes` must be sorted by address and without empty ranges, as `Module.fdes` is. A function
/// whose instructions cannot be read, or that is a signal trampoline, becomes one `unsupported`
/// range. Rows with the same rules as the one before them are merged.
pub fn build(allocator: std.mem.Allocator, fdes: []const ehframe.Fde) BuildError!Table {
    if (fdes.len == 0) return .{ .base = 0, .end = 0, .rows = &.{} };
    const base = fdes[0].pc_begin;

    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(allocator);

    var cursor = base;
    for (fdes) |fde| {
        if (fde.pc_begin < cursor) return error.Overlap;
        if (fde.pc_end <= fde.pc_begin) continue;
        if (fde.pc_begin > cursor) try push(allocator, &rows, cursor - base, gap_row);

        pending.clearRetainingCapacity();
        if (try readRows(allocator, fde, &pending, base)) {
            for (pending.items) |p| try push(allocator, &rows, p.rel, p.content);
        } else {
            try push(allocator, &rows, fde.pc_begin - base, unsupported_row);
        }
        cursor = fde.pc_end;
    }
    try push(allocator, &rows, cursor - base, gap_row);
    const end = std.math.cast(u32, cursor - base) orelse return error.TooLarge;
    return .{ .base = base, .end = end, .rows = try rows.toOwnedSlice(allocator) };
}

fn readRows(allocator: std.mem.Allocator, fde: ehframe.Fde, out: *std.ArrayList(Pending), base: u64) std.mem.Allocator.Error!bool {
    if (fde.cie.signal_frame) return false;
    var it = cfi.rows(fde) catch return false;
    while (true) {
        const next = it.next() catch return false;
        const entry = next orelse return true;
        try out.append(allocator, .{ .rel = entry.start - base, .content = convert(entry.row) });
    }
}

fn push(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), rel: u64, content: Row) BuildError!void {
    const pc = std.math.cast(u32, rel) orelse return error.TooLarge;
    if (rows.items.len > 0 and sameRules(rows.items[rows.items.len - 1], content)) return;
    var row = content;
    row.pc = pc;
    try rows.append(allocator, row);
}

// ------------------------------------------------------- applying a row

/// The three registers that matter for following a stack.
pub const Regs = struct { pc: u64, sp: u64, bp: u64 };

pub const StepError = error{ NoFunction, Unsupported, OutsideStack };

pub const Next = union(enum) { caller: Regs, end };

fn signed(v: i64) u64 {
    return @bitCast(v);
}

/// The registers of the caller, given the row that holds at the frame's address.
pub fn unwind(row: Row, r: Regs, stack: frame.Stack) StepError!Next {
    const kind = cfaKind(row.cfa_type) orelse return error.Unsupported;
    const cfa: u64 = switch (kind) {
        .rsp => r.sp +% signed(row.cfa_offset),
        .rbp => r.bp +% signed(row.cfa_offset),
        .plt => blk: {
            const threshold = std.math.cast(u64, row.cfa_offset) orelse return error.Unsupported;
            break :blk r.sp +% 8 +% (if (r.pc & 15 >= threshold) @as(u64, 8) else 0);
        },
        .end => return .end,
        .unsupported => return error.Unsupported,
        .none => return error.NoFunction,
    };
    const ra = stack.readU64(cfa -% 8) orelse return error.OutsideStack;
    const rbp_kind = rbpKind(row.rbp_type) orelse return error.Unsupported;
    const bp = switch (rbp_kind) {
        .same => r.bp,
        .saved => blk: {
            const slot = cfa +% signed(row.rbp_offset);
            // Below the stack pointer means already popped: rbp holds the caller's value again.
            if (slot < r.sp) break :blk r.bp;
            break :blk stack.readU64(slot) orelse return error.OutsideStack;
        },
    };
    return .{ .caller = .{ .pc = ra, .sp = cfa, .bp = bp } };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn fullRow(cfa_reg: u64, cfa_offset: i64) cfi.Row {
    var row = cfi.Row{ .cfa = .{ .register = .{ .reg = cfa_reg, .offset = cfa_offset } } };
    row.rules[cfi.reg_ra] = .{ .offset = -8 };
    return row;
}

fn kindOf(r: Row) CfaType {
    return cfaKind(r.cfa_type).?;
}

test "convert: ordinary rules fit" {
    var r = convert(fullRow(7, 8));
    try testing.expectEqual(CfaType.rsp, kindOf(r));
    try testing.expectEqual(@as(i32, 8), r.cfa_offset);
    try testing.expectEqual(@as(u8, 0), r.rbp_type);

    var with_frame = fullRow(6, 16);
    with_frame.rules[cfi.reg_rbp] = .{ .offset = -16 };
    r = convert(with_frame);
    try testing.expectEqual(CfaType.rbp, kindOf(r));
    try testing.expectEqual(@as(i32, 16), r.cfa_offset);
    try testing.expectEqual(@as(u8, 1), r.rbp_type);
    try testing.expectEqual(@as(i16, -16), r.rbp_offset);

    var unchanged = fullRow(7, 24);
    unchanged.rules[cfi.reg_rbp] = .same;
    unchanged.rules[3] = .{ .offset = -16 }; // other registers are not tracked
    r = convert(unchanged);
    try testing.expectEqual(CfaType.rsp, kindOf(r));
    try testing.expectEqual(@as(u8, 0), r.rbp_type);

    var outermost = fullRow(7, 8);
    outermost.rules[cfi.reg_ra] = .undef;
    try testing.expectEqual(CfaType.end, kindOf(convert(outermost)));
}

test "convert: what the format cannot hold becomes unsupported" {
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(fullRow(10, 8)))); // CFA from r10
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(fullRow(7, 0x1_0000_0000)))); // offset too large
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(cfi.Row{}))); // nothing set

    var ra = fullRow(7, 8);
    ra.rules[cfi.reg_ra] = .{ .offset = -16 };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(ra)));

    var sp_rule = fullRow(7, 8);
    sp_rule.rules[cfi.reg_rsp] = .{ .offset = -8 };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(sp_rule)));

    var rbp_in_register = fullRow(7, 8);
    rbp_in_register.rules[cfi.reg_rbp] = .{ .register = 3 };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(rbp_in_register)));

    var rbp_far = fullRow(7, 8);
    rbp_far.rules[cfi.reg_rbp] = .{ .offset = -40000 };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(rbp_far)));

    var rbp_lost = fullRow(7, 8);
    rbp_lost.rules[cfi.reg_rbp] = .undef;
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(rbp_lost)));

    var other_expression = cfi.Row{ .cfa = .{ .expression = &.{ 0x77, 0x00 } } };
    other_expression.rules[cfi.reg_ra] = .{ .offset = -8 };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(other_expression)));
}

test "convert: the PLT stub expression, with any threshold, and nothing that only looks like it" {
    const plt11 = [_]u8{ 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a, 0x3b, 0x2a, 0x33, 0x24, 0x22 };
    var row = cfi.Row{ .cfa = .{ .expression = &plt11 } };
    row.rules[cfi.reg_ra] = .{ .offset = -8 };
    const r = convert(row);
    try testing.expectEqual(CfaType.plt, kindOf(r));
    try testing.expectEqual(@as(i32, 11), r.cfa_offset);

    var plt6 = plt11;
    plt6[6] = 0x36; // lit6
    row.cfa = .{ .expression = &plt6 };
    try testing.expectEqual(@as(i32, 6), convert(row).cfa_offset);

    var near_miss = plt11;
    near_miss[9] = 0x25; // shr instead of shl
    row.cfa = .{ .expression = &near_miss };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(row)));

    row.cfa = .{ .expression = plt11[0..10] };
    try testing.expectEqual(CfaType.unsupported, kindOf(convert(row)));
}

const std_cie = [_]u8{ 0x0c, 0x07, 0x08, 0x90, 0x01 };

fn makeFde(begin: u64, end: u64, program: []const u8) ehframe.Fde {
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
            .instructions = &std_cie,
        },
        .instructions = program,
    };
}

test "build: rows cover the functions, gaps are explicit, and find sees both" {
    const fdes = [_]ehframe.Fde{
        makeFde(0x1000, 0x1010, &.{ 0x41, 0x0e, 0x10 }), // advance 1; cfa+16
        makeFde(0x1010, 0x1020, &.{}),
        makeFde(0x1030, 0x1040, &.{}), // after a gap
    };
    var t = try build(testing.allocator, &fdes);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0x1000), t.base);
    try testing.expectEqual(@as(u32, 0x40), t.end);
    try testing.expectEqual(@as(usize, 6), t.rows.len);

    try testing.expectEqual(@as(i32, 8), t.find(0x1000).?.cfa_offset);
    try testing.expectEqual(@as(i32, 16), t.find(0x1001).?.cfa_offset);
    try testing.expectEqual(@as(i32, 16), t.find(0x100f).?.cfa_offset);
    try testing.expectEqual(@as(i32, 8), t.find(0x1010).?.cfa_offset);
    try testing.expectEqual(@as(i32, 8), t.find(0x101f).?.cfa_offset);
    try testing.expect(t.find(0x1020) == null);
    try testing.expect(t.find(0x102f) == null);
    try testing.expect(t.find(0x1030) != null);
    try testing.expect(t.find(0x103f) != null);
    try testing.expect(t.find(0x1040) == null);
    try testing.expect(t.find(0x0fff) == null);
    try testing.expect(t.find(std.math.maxInt(u64)) == null);
}

test "build: neighbouring functions with the same rules share a row" {
    const fdes = [_]ehframe.Fde{ makeFde(0x1000, 0x1010, &.{}), makeFde(0x1010, 0x1020, &.{}) };
    var t = try build(testing.allocator, &fdes);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), t.rows.len); // one row for both, one for the end
}

test "build: functions that cannot be read become unsupported ranges, and the others are unaffected" {
    var signal = makeFde(0x1020, 0x1030, &.{});
    signal.cie.signal_frame = true;
    const fdes = [_]ehframe.Fde{
        makeFde(0x1000, 0x1010, &.{}),
        makeFde(0x1010, 0x1020, &.{0x30}), // an instruction this reader does not know
        signal,
        makeFde(0x1030, 0x1040, &.{}),
    };
    var t = try build(testing.allocator, &fdes);
    defer t.deinit(testing.allocator);

    try testing.expectEqual(CfaType.rsp, kindOf(t.find(0x1000).?));
    try testing.expectEqual(CfaType.unsupported, kindOf(t.find(0x1010).?));
    try testing.expectEqual(CfaType.unsupported, kindOf(t.find(0x101f).?));
    try testing.expectEqual(CfaType.unsupported, kindOf(t.find(0x1020).?));
    try testing.expectEqual(CfaType.rsp, kindOf(t.find(0x1030).?));
}

test "build: overlaps and ranges too far apart for 32 bits are errors, and no functions is an empty table" {
    const overlapping = [_]ehframe.Fde{ makeFde(0x1000, 0x1020, &.{}), makeFde(0x1010, 0x1030, &.{}) };
    try testing.expectError(error.Overlap, build(testing.allocator, &overlapping));

    const far = [_]ehframe.Fde{ makeFde(0x1000, 0x1010, &.{}), makeFde(0x1_0000_2000, 0x1_0000_2010, &.{}) };
    try testing.expectError(error.TooLarge, build(testing.allocator, &far));

    var t = try build(testing.allocator, &.{});
    defer t.deinit(testing.allocator);
    try testing.expect(t.find(0x1000) == null);
    try testing.expect(t.find(0) == null);
}

test "unwind: each kind of row gives the caller's registers" {
    var mem = [_]u8{0} ** 0x40;
    std.mem.writeInt(u64, mem[0x00..][0..8], 0x2222, .little);
    std.mem.writeInt(u64, mem[0x18..][0..8], 0x3333, .little);
    std.mem.writeInt(u64, mem[0x10..][0..8], 0x7050, .little);
    const stack = frame.Stack{ .base = 0x7000, .bytes = &mem };

    // The CFA from rsp, rbp unchanged.
    var row = convert(fullRow(7, 8));
    var next = try unwind(row, .{ .pc = 0x1000, .sp = 0x7000, .bp = 0xabcd }, stack);
    try testing.expectEqual(@as(u64, 0x2222), next.caller.pc);
    try testing.expectEqual(@as(u64, 0x7008), next.caller.sp);
    try testing.expectEqual(@as(u64, 0xabcd), next.caller.bp);

    // The CFA from rbp, rbp saved at CFA-16.
    var with_frame = fullRow(6, 16);
    with_frame.rules[cfi.reg_rbp] = .{ .offset = -16 };
    row = convert(with_frame);
    next = try unwind(row, .{ .pc = 0x1010, .sp = 0x7000, .bp = 0x7010 }, stack);
    try testing.expectEqual(@as(u64, 0x3333), next.caller.pc);
    try testing.expectEqual(@as(u64, 0x7020), next.caller.sp);
    try testing.expectEqual(@as(u64, 0x7050), next.caller.bp);

    // A PLT stub: the CFA is 8 more once the pc is in the last part of the 16 bytes.
    const plt11 = [_]u8{ 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a, 0x3b, 0x2a, 0x33, 0x24, 0x22 };
    var plt_full = cfi.Row{ .cfa = .{ .expression = &plt11 } };
    plt_full.rules[cfi.reg_ra] = .{ .offset = -8 };
    row = convert(plt_full);
    try testing.expectEqual(@as(u64, 0x7008), (try unwind(row, .{ .pc = 0x100a, .sp = 0x7000, .bp = 0 }, stack)).caller.sp);
    try testing.expectEqual(@as(u64, 0x7010), (try unwind(row, .{ .pc = 0x100b, .sp = 0x7000, .bp = 0 }, stack)).caller.sp);
}

test "unwind: the outermost frame, and the reasons a row cannot be followed" {
    var mem = [_]u8{0} ** 0x40;
    const stack = frame.Stack{ .base = 0x7000, .bytes = &mem };
    const regs = Regs{ .pc = 0x1000, .sp = 0x7000, .bp = 0 };

    var outermost = fullRow(7, 8);
    outermost.rules[cfi.reg_ra] = .undef;
    try testing.expect((try unwind(convert(outermost), regs, stack)) == .end);

    try testing.expectError(error.Unsupported, unwind(unsupported_row, regs, stack));
    try testing.expectError(error.NoFunction, unwind(gap_row, regs, stack));
    try testing.expectError(error.OutsideStack, unwind(convert(fullRow(7, 0x2000)), regs, stack));
    var bad = convert(fullRow(7, 8));
    bad.cfa_type = 99; // not a kind this format has
    try testing.expectError(error.Unsupported, unwind(bad, regs, stack));
}

test "unwind: an rbp saved below the stack pointer has already been restored" {
    var mem = [_]u8{0} ** 0x40;
    std.mem.writeInt(u64, mem[0..8], 0x2222, .little);
    const stack = frame.Stack{ .base = 0x7000, .bytes = &mem };

    var full = fullRow(7, 8); // the instruction between pop rbp and ret
    full.rules[cfi.reg_rbp] = .{ .offset = -16 };
    const next = try unwind(convert(full), .{ .pc = 0x1000, .sp = 0x7000, .bp = 0xabcd }, stack);
    try testing.expectEqual(@as(u64, 0x2222), next.caller.pc);
    try testing.expectEqual(@as(u64, 0xabcd), next.caller.bp);
}
