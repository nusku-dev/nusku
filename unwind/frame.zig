//! Applies one row of unwind rules to the registers of a frame, to get the registers of the
//! frame that called it.
const std = @import("std");
const cfi = @import("cfi.zig");

pub const num_regs = cfi.num_regs;

pub const Error = error{
    /// A rule or an expression needs something this unwinder does not do.
    Unsupported,
    /// A rule or an expression is not well formed.
    Malformed,
    /// A rule needs a register whose value was lost.
    UnknownRegister,
    /// A rule points at memory that the stack snapshot does not hold.
    OutsideStack,
};

const all_known: u32 = (1 << num_regs) - 1;

/// The registers of one frame, in DWARF numbering. Index 16 holds the instruction pointer.
pub const Frame = struct {
    regs: [num_regs]u64,
    /// Bit i is set when regs[i] holds a real value.
    known: u32 = all_known,

    pub fn pc(self: Frame) u64 {
        return self.regs[cfi.reg_ra];
    }

    pub fn sp(self: Frame) u64 {
        return self.regs[cfi.reg_rsp];
    }
};

/// A copy of memory from the stack pointer upwards.
pub const Stack = struct {
    /// The address of bytes[0].
    base: u64,
    bytes: []const u8,

    pub fn readU64(self: Stack, addr: u64) ?u64 {
        if (addr < self.base) return null;
        const offset = addr - self.base;
        const len: u64 = self.bytes.len;
        if (offset > len or len - offset < 8) return null;
        const at: usize = @intCast(offset);
        return std.mem.readInt(u64, self.bytes[at..][0..8], .little);
    }
};

pub const Next = union(enum) {
    /// The registers of the caller.
    caller: Frame,
    /// The return address is marked undefined: this was the outermost frame.
    outermost,
};

fn bitOf(reg: usize) u32 {
    return @as(u32, 1) << @intCast(reg);
}

fn regValue(frame: Frame, reg: u64) Error!u64 {
    if (reg >= num_regs) return error.Unsupported;
    const i: usize = @intCast(reg);
    if (frame.known & bitOf(i) == 0) return error.UnknownRegister;
    return frame.regs[i];
}

/// The Canonical Frame Address of `frame` under `row`: the stack pointer of the caller.
pub fn cfaOf(row: cfi.Row, frame: Frame, stack: Stack) Error!u64 {
    switch (row.cfa) {
        .unset => return error.Malformed,
        .register => |c| return (try regValue(frame, c.reg)) +% @as(u64, @bitCast(c.offset)),
        .expression => |e| return eval(e, frame, stack, null),
    }
}

/// The registers of the caller of `frame`, given the row that holds at the frame's address.
pub fn unwindOne(row: cfi.Row, frame: Frame, stack: Stack) Error!Next {
    const cfa = try cfaOf(row, frame, stack);

    var caller = frame;
    var i: usize = 0;
    while (i < num_regs) : (i += 1) {
        const rule = row.rules[i];
        if (i == cfi.reg_ra) {
            switch (rule) {
                .undef => return .outermost,
                .unspecified => return error.Malformed, // nothing says where the caller is
                else => {},
            }
        }
        // Every rule refers to the registers of this frame, not to ones already changed.
        switch (try applyRule(rule, cfa, frame, stack, i == cfi.reg_ra)) {
            .keep => {},
            .lost => caller.known &= ~bitOf(i),
            .value => |v| {
                caller.regs[i] = v;
                caller.known |= bitOf(i);
            },
        }
    }
    // The stack pointer of the caller is the CFA, unless a rule says otherwise.
    switch (row.rules[cfi.reg_rsp]) {
        .unspecified => {
            caller.regs[cfi.reg_rsp] = cfa;
            caller.known |= bitOf(cfi.reg_rsp);
        },
        else => {},
    }
    return .{ .caller = caller };
}

const Value = union(enum) { keep, lost, value: u64 };

fn applyRule(rule: cfi.Rule, cfa: u64, frame: Frame, stack: Stack, is_return_address: bool) Error!Value {
    switch (rule) {
        .unspecified, .same => return .keep, // an unmentioned register keeps its value
        .undef => return .lost,
        .offset => |n| {
            const at = cfa +% @as(u64, @bitCast(n));
            // A register saved below the stack pointer has already been popped, so the register
            // holds the caller's value again; compilers leave the rule in place until the ret.
            if (!is_return_address and at < frame.sp()) return .keep;
            return .{ .value = stack.readU64(at) orelse return error.OutsideStack };
        },
        .val_offset => |n| return .{ .value = cfa +% @as(u64, @bitCast(n)) },
        .register => |r| return .{ .value = try regValue(frame, r) },
        .expression => |e| {
            const at = try eval(e, frame, stack, cfa);
            return .{ .value = stack.readU64(at) orelse return error.OutsideStack };
        },
        .val_expression => |e| return .{ .value = try eval(e, frame, stack, cfa) },
    }
}
// ------------------------------------------------------- DWARF expressions

const max_stack = 16;

fn push(values: *[max_stack]u64, n: *usize, v: u64) Error!void {
    if (n.* == max_stack) return error.Malformed;
    values[n.*] = v;
    n.* += 1;
}

fn pop(values: *[max_stack]u64, n: *usize) Error!u64 {
    if (n.* == 0) return error.Malformed;
    n.* -= 1;
    return values[n.*];
}

fn uleb(expr: []const u8, pos: *usize) Error!u64 {
    var result: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (pos.* >= expr.len or shift >= 64) return error.Malformed;
        const byte = expr[pos.*];
        pos.* += 1;
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return result;
        shift += 7;
    }
}

fn sleb(expr: []const u8, pos: *usize) Error!i64 {
    var result: i64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (pos.* >= expr.len or shift >= 64) return error.Malformed;
        const byte = expr[pos.*];
        pos.* += 1;
        result |= @as(i64, byte & 0x7f) << @intCast(shift);
        shift += 7;
        if (byte & 0x80 == 0) {
            if (shift < 64 and byte & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
            return result;
        }
    }
}

/// A little-endian number of `size` bytes, sign extended if asked to.
fn fixed(expr: []const u8, pos: *usize, size: usize, signed: bool) Error!u64 {
    if (size > expr.len - pos.*) return error.Malformed;
    var v: u64 = 0;
    for (0..size) |i| v |= @as(u64, expr[pos.* + i]) << @intCast(8 * i);
    pos.* += size;
    if (signed and size < 8) {
        const sh: u6 = @intCast(64 - size * 8);
        return @bitCast(@as(i64, @bitCast(v << sh)) >> sh);
    }
    return v;
}

fn binary(op: u8, a: u64, b: u64) u64 {
    const sa: i64 = @bitCast(a);
    const sb: i64 = @bitCast(b);
    return switch (op) {
        0x1a => a & b,
        0x1c => a -% b,
        0x1e => a *% b,
        0x21 => a | b,
        0x22 => a +% b,
        0x24 => if (b >= 64) 0 else a << @intCast(b),
        0x25 => if (b >= 64) 0 else a >> @intCast(b),
        0x26 => if (b >= 64) (if (sa < 0) ~@as(u64, 0) else 0) else @as(u64, @bitCast(sa >> @intCast(b))),
        0x27 => a ^ b,
        // Comparisons are signed, as in libgcc. The second value down is compared with the top one.
        0x29 => @intFromBool(sa == sb),
        0x2a => @intFromBool(sa >= sb),
        0x2b => @intFromBool(sa > sb),
        0x2c => @intFromBool(sa <= sb),
        0x2d => @intFromBool(sa < sb),
        0x2e => @intFromBool(sa != sb),
        else => unreachable,
    };
}

/// Evaluates a DWARF expression and returns the value on top of its stack. `initial`, when
/// given, is the value the stack starts with (the CFA, for the expressions of register rules).
/// Branches, calls and the typed operations are not supported.
pub fn eval(expr: []const u8, frame: Frame, stack: Stack, initial: ?u64) Error!u64 {
    var values: [max_stack]u64 = undefined;
    var n: usize = 0;
    if (initial) |v| try push(&values, &n, v);

    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        switch (op) {
            0x30...0x4f => try push(&values, &n, op - 0x30), // lit0 to lit31
            0x70...0x8f => { // breg0 to breg31: a register plus a signed offset
                const offset = try sleb(expr, &pos);
                const value = try regValue(frame, op - 0x70);
                try push(&values, &n, value +% @as(u64, @bitCast(offset)));
            },
            0x08 => try push(&values, &n, try fixed(expr, &pos, 1, false)),
            0x09 => try push(&values, &n, try fixed(expr, &pos, 1, true)),
            0x0a => try push(&values, &n, try fixed(expr, &pos, 2, false)),
            0x0b => try push(&values, &n, try fixed(expr, &pos, 2, true)),
            0x0c => try push(&values, &n, try fixed(expr, &pos, 4, false)),
            0x0d => try push(&values, &n, try fixed(expr, &pos, 4, true)),
            0x0e => try push(&values, &n, try fixed(expr, &pos, 8, false)),
            0x0f => try push(&values, &n, try fixed(expr, &pos, 8, true)),
            0x10 => try push(&values, &n, try uleb(expr, &pos)),
            0x11 => try push(&values, &n, @bitCast(try sleb(expr, &pos))),
            0x06 => { // deref: the 8 bytes at the address on top
                const at = try pop(&values, &n);
                try push(&values, &n, stack.readU64(at) orelse return error.OutsideStack);
            },
            0x23 => { // plus_uconst
                const a = try pop(&values, &n);
                try push(&values, &n, a +% try uleb(expr, &pos));
            },
            0x19 => { // abs
                const a = try pop(&values, &n);
                const sa: i64 = @bitCast(a);
                try push(&values, &n, if (sa < 0) 0 -% a else a);
            },
            0x1f => try push(&values, &n, 0 -% try pop(&values, &n)), // neg
            0x20 => try push(&values, &n, ~(try pop(&values, &n))), // not
            0x12 => { // dup
                const a = try pop(&values, &n);
                try push(&values, &n, a);
                try push(&values, &n, a);
            },
            0x13 => _ = try pop(&values, &n), // drop
            0x14 => { // over
                const b = try pop(&values, &n);
                const a = try pop(&values, &n);
                try push(&values, &n, a);
                try push(&values, &n, b);
                try push(&values, &n, a);
            },
            0x16 => { // swap
                const b = try pop(&values, &n);
                const a = try pop(&values, &n);
                try push(&values, &n, b);
                try push(&values, &n, a);
            },
            0x96 => {}, // nop
            0x1a, 0x1c, 0x1e, 0x21, 0x22, 0x24, 0x25, 0x26, 0x27, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e => {
                const b = try pop(&values, &n);
                const a = try pop(&values, &n);
                try push(&values, &n, binary(op, a, b));
            },
            else => return error.Unsupported,
        }
    }
    if (n == 0) return error.Malformed;
    return values[n - 1];
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn putWord(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

fn testFrame(pc: u64, sp: u64) Frame {
    var f = Frame{ .regs = [_]u64{0} ** num_regs };
    f.regs[cfi.reg_ra] = pc;
    f.regs[cfi.reg_rsp] = sp;
    return f;
}

/// The row of a normal function: the CFA is a register plus an offset, and the return
/// address is stored just below the CFA.
fn standardRow(cfa_reg: u64, cfa_offset: i64) cfi.Row {
    var row = cfi.Row{ .cfa = .{ .register = .{ .reg = cfa_reg, .offset = cfa_offset } } };
    row.rules[cfi.reg_ra] = .{ .offset = -8 };
    return row;
}

fn callerOf(row: cfi.Row, frame: Frame, stack: Stack) !Frame {
    return switch (try unwindOne(row, frame, stack)) {
        .caller => |c| c,
        .outermost => error.TestUnexpectedResult,
    };
}

test "a function that has just been entered: the return address is on top of the stack" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0, 0x2222);
    var f = testFrame(0x1000, 0x7000);
    f.regs[cfi.reg_rbp] = 0xabcd;

    const caller = try callerOf(standardRow(7, 8), f, .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u64, 0x2222), caller.pc());
    try testing.expectEqual(@as(u64, 0x7008), caller.sp());
    try testing.expectEqual(@as(u64, 0xabcd), caller.regs[cfi.reg_rbp]); // not mentioned: unchanged
    try testing.expectEqual(all_known, caller.known);
}

test "a function with a frame pointer: the CFA comes from rbp and rbp is restored from the stack" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0x18, 0x2222); // the return address, at CFA-8
    putWord(&mem, 0x10, 0x7050); // the caller's rbp, at CFA-16
    var f = testFrame(0x1010, 0x7000);
    f.regs[cfi.reg_rbp] = 0x7010;

    var row = standardRow(6, 16);
    row.rules[cfi.reg_rbp] = .{ .offset = -16 };
    const caller = try callerOf(row, f, .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u64, 0x2222), caller.pc());
    try testing.expectEqual(@as(u64, 0x7020), caller.sp());
    try testing.expectEqual(@as(u64, 0x7050), caller.regs[cfi.reg_rbp]);
}

test "an rbp holding garbage does not matter when the row does not use it" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0x18, 0x2222);
    putWord(&mem, 0x10, 0x7050); // the real rbp of the caller, saved by the prologue
    var f = testFrame(0x1010, 0x7000);
    f.regs[cfi.reg_rbp] = 0xe9b5dba5b5c0fbcf; // what the assembly routine left in it

    var row = standardRow(7, 0x20); // the CFA from rsp
    row.rules[cfi.reg_rbp] = .{ .offset = -16 };
    const caller = try callerOf(row, f, .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u64, 0x2222), caller.pc());
    try testing.expectEqual(@as(u64, 0x7020), caller.sp());
    try testing.expectEqual(@as(u64, 0x7050), caller.regs[cfi.reg_rbp]);
}

test "the outermost frame is the one whose return address is undefined" {
    var row = standardRow(7, 8);
    row.rules[cfi.reg_ra] = .undef;
    const next = try unwindOne(row, testFrame(0x1000, 0x7000), .{ .base = 0, .bytes = &.{} });
    try testing.expect(next == .outermost);
}

test "saved registers: stored, computed, copied from another register, or unchanged" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0x18, 0x2222); // return address
    putWord(&mem, 0x10, 0xbbbb); // rbx
    putWord(&mem, 0x08, 0xcccc); // r12
    var f = testFrame(0x1010, 0x7000);
    f.regs[3] = 0xb0; // rbx now
    f.regs[15] = 0xf5; // r15

    var row = standardRow(7, 0x20);
    row.rules[3] = .{ .offset = -16 };
    row.rules[12] = .{ .offset = -24 };
    row.rules[13] = .{ .val_offset = 8 };
    row.rules[14] = .{ .register = 3 };
    row.rules[15] = .same;
    const caller = try callerOf(row, f, .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u64, 0xbbbb), caller.regs[3]);
    try testing.expectEqual(@as(u64, 0xcccc), caller.regs[12]);
    try testing.expectEqual(@as(u64, 0x7028), caller.regs[13]);
    try testing.expectEqual(@as(u64, 0xb0), caller.regs[14]); // the value rbx had in this frame
    try testing.expectEqual(@as(u64, 0xf5), caller.regs[15]);
}

test "a register marked lost becomes unknown, and a later row that needs it fails" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0, 0x2222);
    var row = standardRow(7, 8);
    row.rules[3] = .undef;
    const caller = try callerOf(row, testFrame(0x1000, 0x7000), .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u32, 0), caller.known & bitOf(3));
    try testing.expect(caller.known & bitOf(6) != 0);

    const next_row = cfi.Row{ .cfa = .{ .register = .{ .reg = 3, .offset = 0 } } };
    try testing.expectError(error.UnknownRegister, cfaOf(next_row, caller, .{ .base = 0, .bytes = &.{} }));
}

test "a PLT stub: the CFA is an expression that depends on where in the stub the pc is" {
    // rsp + 8 + ((rip & 15) >= 11 ? 8 : 0), the expression compilers write for PLT entries
    const plt = [_]u8{ 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a, 0x3b, 0x2a, 0x33, 0x24, 0x22 };
    const row = cfi.Row{ .cfa = .{ .expression = &plt } };
    const none = Stack{ .base = 0, .bytes = &.{} };

    try testing.expectEqual(@as(u64, 0x7008), try cfaOf(row, testFrame(0x1000, 0x7000), none));
    try testing.expectEqual(@as(u64, 0x7008), try cfaOf(row, testFrame(0x100a, 0x7000), none));
    try testing.expectEqual(@as(u64, 0x7010), try cfaOf(row, testFrame(0x100b, 0x7000), none));
    try testing.expectEqual(@as(u64, 0x7010), try cfaOf(row, testFrame(0x100f, 0x7000), none));
}

test "rules that cannot be followed give errors" {
    var mem = [_]u8{0} ** 64;
    const stack = Stack{ .base = 0x7000, .bytes = &mem };
    const f = testFrame(0x1000, 0x7000);

    // The return address lies outside the snapshot.
    try testing.expectError(error.OutsideStack, unwindOne(standardRow(7, 0x2000), f, stack));
    // No CFA rule, no return address rule, a register that does not exist.
    try testing.expectError(error.Malformed, unwindOne(cfi.Row{}, f, stack));
    try testing.expectError(error.Malformed, unwindOne(cfi.Row{ .cfa = .{ .register = .{ .reg = 7, .offset = 8 } } }, f, stack));
    try testing.expectError(error.Unsupported, unwindOne(standardRow(20, 8), f, stack));
}

test "expressions: constants, arithmetic, comparisons and stack operations" {
    const f = testFrame(0x100b, 0x7000);
    const none = Stack{ .base = 0, .bytes = &.{} };

    try testing.expectEqual(@as(u64, 12), try eval(&.{ 0x35, 0x23, 0x07 }, f, none, null)); // lit5, plus_uconst 7
    try testing.expectEqual(@as(u64, 0x6ff8), try eval(&.{ 0x77, 0x78 }, f, none, null)); // rsp - 8
    try testing.expectEqual(@as(u64, 0x100b), try eval(&.{ 0x80, 0x00 }, f, none, null)); // rip
    try testing.expectEqual(@as(u64, 4), try eval(&.{ 0x37, 0x33, 0x1c }, f, none, null)); // 7 - 3
    try testing.expectEqual(@as(u64, 42), try eval(&.{ 0x36, 0x37, 0x1e }, f, none, null)); // 6 * 7
    try testing.expectEqual(@as(u64, 16), try eval(&.{ 0x31, 0x34, 0x24 }, f, none, null)); // 1 << 4
    try testing.expectEqual(@as(u64, 4), try eval(&.{ 0x40, 0x32, 0x25 }, f, none, null)); // 16 >> 2
    try testing.expectEqual(@as(u64, 0x0c), try eval(&.{ 0x08, 0x0f, 0x08, 0x3c, 0x1a }, f, none, null)); // 0x0f & 0x3c
    try testing.expectEqual(@as(u64, 3), try eval(&.{ 0x31, 0x32, 0x21 }, f, none, null)); // 1 | 2
    try testing.expectEqual(@as(u64, 2), try eval(&.{ 0x33, 0x31, 0x27 }, f, none, null)); // 3 ^ 1
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -5))), try eval(&.{ 0x35, 0x1f }, f, none, null)); // neg
    try testing.expectEqual(~@as(u64, 0), try eval(&.{ 0x30, 0x20 }, f, none, null)); // not
    try testing.expectEqual(@as(u64, 1), try eval(&.{ 0x33, 0x35, 0x2d }, f, none, null)); // 3 < 5
    try testing.expectEqual(@as(u64, 0), try eval(&.{ 0x35, 0x33, 0x2d }, f, none, null)); // 5 < 3
    try testing.expectEqual(@as(u64, 1), try eval(&.{ 0x09, 0xff, 0x31, 0x2d }, f, none, null)); // -1 < 1, signed
    try testing.expectEqual(@as(u64, 8), try eval(&.{ 0x34, 0x12, 0x22 }, f, none, null)); // dup, plus
    try testing.expectEqual(@as(u64, 1), try eval(&.{ 0x31, 0x32, 0x16 }, f, none, null)); // swap
    try testing.expectEqual(@as(u64, 1), try eval(&.{ 0x31, 0x32, 0x14 }, f, none, null)); // over
    try testing.expectEqual(@as(u64, 9), try eval(&.{ 0x39, 0x31, 0x13 }, f, none, null)); // drop
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), try eval(&.{ 0x11, 0x7f }, f, none, null)); // consts
    try testing.expectEqual(@as(u64, 624485), try eval(&.{ 0x10, 0xe5, 0x8e, 0x26 }, f, none, null)); // constu
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -32768))), try eval(&.{ 0x0b, 0x00, 0x80 }, f, none, null)); // const2s
    try testing.expectEqual(@as(u64, 0x0102030405060708), try eval(&.{ 0x0e, 8, 7, 6, 5, 4, 3, 2, 1 }, f, none, null));
    try testing.expectEqual(@as(u64, 0x108), try eval(&.{ 0x23, 0x08 }, f, none, 0x100)); // starts from the given value
}

test "expressions can read the stack, and fail cleanly when they cannot" {
    var mem = [_]u8{0} ** 16;
    putWord(&mem, 0, 0x2222);
    const f = testFrame(0x1000, 0x7000);
    const stack = Stack{ .base = 0x7000, .bytes = &mem };
    const none = Stack{ .base = 0, .bytes = &.{} };

    try testing.expectEqual(@as(u64, 0x2222), try eval(&.{ 0x77, 0x00, 0x06 }, f, stack, null)); // *rsp
    try testing.expectError(error.OutsideStack, eval(&.{ 0x77, 0x00, 0x06 }, f, none, null));

    try testing.expectError(error.Malformed, eval(&.{}, f, none, null));
    try testing.expectError(error.Malformed, eval(&.{0x22}, f, none, null)); // plus with nothing to add
    try testing.expectError(error.Malformed, eval(&.{0x77}, f, none, null)); // an offset is missing
    try testing.expectError(error.Unsupported, eval(&.{0x28}, f, none, null)); // a branch
    try testing.expectError(error.Unsupported, eval(&.{ 0x84, 0x00 }, f, none, null)); // register 20

    var g = f;
    g.known &= ~@as(u32, 1 << 3);
    try testing.expectError(error.UnknownRegister, eval(&.{ 0x73, 0x00 }, g, none, null)); // rbx + 0

    const too_deep = [_]u8{0x30} ** 17;
    try testing.expectError(error.Malformed, eval(&too_deep, f, none, null));
}

test "reading the stack snapshot stops at its edges" {
    var mem = [_]u8{0} ** 16;
    putWord(&mem, 0, 1);
    putWord(&mem, 8, 2);
    const stack = Stack{ .base = 0x1000, .bytes = &mem };

    try testing.expectEqual(@as(?u64, 1), stack.readU64(0x1000));
    try testing.expectEqual(@as(?u64, 2), stack.readU64(0x1008));
    try testing.expectEqual(@as(?u64, null), stack.readU64(0x1009)); // would end past the snapshot
    try testing.expectEqual(@as(?u64, null), stack.readU64(0x0fff));
    try testing.expectEqual(@as(?u64, null), stack.readU64(0x1010));
    try testing.expectEqual(@as(?u64, null), stack.readU64(std.math.maxInt(u64)));
}

test "a register saved below the stack pointer has already been popped, so it is unchanged" {
    var mem = [_]u8{0} ** 64;
    putWord(&mem, 0, 0x2222); // the return address, on top of the stack: the CFA is rsp+8
    var f = testFrame(0x1000, 0x7000);
    f.regs[3] = 0xb0;

    var row = standardRow(7, 8);
    row.rules[3] = .{ .offset = -16 }; // rbx, saved at CFA-16 = 0x6ff8, below the stack pointer
    const caller = try callerOf(row, f, .{ .base = 0x7000, .bytes = &mem });
    try testing.expectEqual(@as(u64, 0xb0), caller.regs[3]);
    try testing.expectEqual(@as(u64, 0x2222), caller.pc());

    // The return address is never excused: its slot below the stack pointer is an error.
    try testing.expectError(error.OutsideStack, unwindOne(standardRow(7, 0), f, .{ .base = 0x7000, .bytes = &mem }));
}
