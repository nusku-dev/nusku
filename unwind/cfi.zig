//! Runs the instructions of .eh_frame entries (DWARF call frame information) to find out how
//! to get from a function's frame to its caller's frame at any address of that function.
//!
//! Only x86-64 is known here: the register numbers, their names, and the return address in
//! column 16. This file computes rules only; applying them to register values comes next.
const std = @import("std");
const ehframe = @import("ehframe.zig");

pub const Error = error{ Truncated, Malformed, Unsupported };

/// DWARF register numbers on x86-64: 0 to 15 are rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, r8 to
/// r15, and 16 is the return address. Rules for any other register (the vector registers)
/// are read and ignored, because they never matter for finding the caller.
pub const num_regs = 17;
pub const reg_rbp = 6;
pub const reg_rsp = 7;
pub const reg_ra = 16;

const reg_names = [num_regs][]const u8{
    "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    "ra",
};

/// What happened to a register when the function was entered, seen from its caller.
pub const Rule = union(enum) {
    /// Nothing says anything about it.
    unspecified,
    /// The caller's value is lost. For the return address this marks the outermost frame.
    undef,
    /// The caller's value is the register's current value.
    same,
    /// Saved in memory at CFA + n.
    offset: i64,
    /// The caller's value is CFA + n, and nothing is stored.
    val_offset: i64,
    /// Held in another register.
    register: u64,
    /// Saved in memory at the address this DWARF expression computes. Points into the section.
    expression: []const u8,
    /// The caller's value is what this DWARF expression computes. Points into the section.
    val_expression: []const u8,
};

/// The Canonical Frame Address: the value the stack pointer had in the caller before the call.
pub const Cfa = union(enum) {
    unset,
    register: struct { reg: u64, offset: i64 },
    /// Points into the section. Compilers write this for PLT stubs.
    expression: []const u8,
};

pub const Row = struct {
    cfa: Cfa = .unset,
    rules: [num_regs]Rule = [_]Rule{.unspecified} ** num_regs,
};

/// The rule row that holds for the addresses start <= pc < end.
pub const Entry = struct {
    start: u64,
    end: u64,
    row: Row,
};

/// The rows of one function, in address order. They cover exactly pc_begin to pc_end.
pub fn rows(fde: ehframe.Fde) Error!RowIterator {
    return .{
        .machine = try Machine.init(fde),
        .program = Program{ .bytes = fde.instructions },
        .pc_end = fde.pc_end,
    };
}

/// The row that holds at `pc`, or null if the function does not cover that address.
pub fn rowAt(fde: ehframe.Fde, pc: u64) Error!?Row {
    if (pc < fde.pc_begin or pc >= fde.pc_end) return null;
    var it = try rows(fde);
    while (try it.next()) |entry| {
        if (pc >= entry.start and pc < entry.end) return entry.row;
    }
    return null;
}

pub const RowIterator = struct {
    machine: Machine,
    program: Program,
    pc_end: u64,
    done: bool = false,

    pub fn next(self: *RowIterator) Error!?Entry {
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

// ---------------------------------------------------------------- the machine

const max_saved = 8;

const Program = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn atEnd(self: Program) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Program, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Truncated;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn readU8(self: *Program) Error!u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Program) Error!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn readU32(self: *Program) Error!u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn uleb(self: *Program) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try self.readU8();
            if (shift >= 64) return error.Malformed;
            if (shift == 63 and byte & 0x7e != 0) return error.Malformed;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn sleb(self: *Program) Error!i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try self.readU8();
            if (shift >= 64) return error.Malformed;
            result |= @as(i64, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if (byte & 0x80 == 0) break;
        }
        if (shift < 64 and byte & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
        return result;
    }
};

/// A length-prefixed block of bytes, as used by the expression instructions.
fn block(p: *Program) Error![]const u8 {
    const len = std.math.cast(usize, try p.uleb()) orelse return error.Malformed;
    return p.take(len);
}

fn toSigned(n: u64) Error!i64 {
    return std.math.cast(i64, n) orelse return error.Malformed;
}

const Machine = struct {
    cie: ehframe.Cie,
    /// The rules the CIE sets; what DW_CFA_restore goes back to.
    initial: Row = .{},
    row: Row = .{},
    saved: [max_saved]Row = undefined,
    depth: usize = 0,
    /// Where the current row starts.
    loc: u64,

    fn init(fde: ehframe.Fde) Error!Machine {
        var m = Machine{ .cie = fde.cie, .loc = fde.pc_begin };
        var program = Program{ .bytes = fde.cie.instructions };
        // The CIE sets starting rules; it cannot move to another address.
        if (try m.runToAdvance(&program)) |_| return error.Malformed;
        m.initial = m.row;
        return m;
    }

    /// Executes instructions until one that moves the location, and returns the address it
    /// moves to; the current row is the one that holds below that address. Returns null when
    /// the program ends.
    fn runToAdvance(self: *Machine, p: *Program) Error!?u64 {
        while (!p.atEnd()) {
            const op = try p.readU8();
            switch (op & 0xc0) {
                0x40 => return try self.advance(op & 0x3f),
                0x80 => {
                    const n = try toSigned(try p.uleb());
                    self.setRule(op & 0x3f, .{ .offset = try self.factor(n) });
                },
                0xc0 => self.restore(op & 0x3f),
                else => switch (op) {
                    0x00 => {}, // nop
                    0x02 => return try self.advance(try p.readU8()),
                    0x03 => return try self.advance(try p.readU16()),
                    0x04 => return try self.advance(try p.readU32()),
                    0x05 => { // offset_extended
                        const reg = try p.uleb();
                        const n = try toSigned(try p.uleb());
                        self.setRule(reg, .{ .offset = try self.factor(n) });
                    },
                    0x06 => self.restore(try p.uleb()), // restore_extended
                    0x07 => self.setRule(try p.uleb(), .undef),
                    0x08 => self.setRule(try p.uleb(), .same),
                    0x09 => { // register
                        const reg = try p.uleb();
                        self.setRule(reg, .{ .register = try p.uleb() });
                    },
                    0x0a => try self.remember(),
                    0x0b => try self.recall(),
                    0x0c => { // def_cfa: the offset is not factored
                        const reg = try p.uleb();
                        const offset = try toSigned(try p.uleb());
                        self.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
                    },
                    0x0d => { // def_cfa_register
                        const reg = try p.uleb();
                        switch (self.row.cfa) {
                            .register => |*c| c.reg = reg,
                            else => return error.Malformed,
                        }
                    },
                    0x0e => { // def_cfa_offset
                        const offset = try toSigned(try p.uleb());
                        switch (self.row.cfa) {
                            .register => |*c| c.offset = offset,
                            else => return error.Malformed,
                        }
                    },
                    0x0f => self.row.cfa = .{ .expression = try block(p) }, // def_cfa_expression
                    0x10 => { // expression
                        const reg = try p.uleb();
                        self.setRule(reg, .{ .expression = try block(p) });
                    },
                    0x11 => { // offset_extended_sf
                        const reg = try p.uleb();
                        self.setRule(reg, .{ .offset = try self.factor(try p.sleb()) });
                    },
                    0x12 => { // def_cfa_sf
                        const reg = try p.uleb();
                        const offset = try self.factor(try p.sleb());
                        self.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
                    },
                    0x13 => { // def_cfa_offset_sf
                        const offset = try self.factor(try p.sleb());
                        switch (self.row.cfa) {
                            .register => |*c| c.offset = offset,
                            else => return error.Malformed,
                        }
                    },
                    0x14 => { // val_offset
                        const reg = try p.uleb();
                        const n = try toSigned(try p.uleb());
                        self.setRule(reg, .{ .val_offset = try self.factor(n) });
                    },
                    0x15 => { // val_offset_sf
                        const reg = try p.uleb();
                        self.setRule(reg, .{ .val_offset = try self.factor(try p.sleb()) });
                    },
                    0x16 => { // val_expression
                        const reg = try p.uleb();
                        self.setRule(reg, .{ .val_expression = try block(p) });
                    },
                    0x2e => _ = try p.uleb(), // GNU_args_size: matters for landing pads, not for the caller's frame
                    else => return error.Unsupported,
                },
            }
        }
        return null;
    }

    fn advance(self: *Machine, delta: u64) Error!u64 {
        const by = std.math.mul(u64, delta, self.cie.code_align) catch return error.Malformed;
        return std.math.add(u64, self.loc, by) catch return error.Malformed;
    }

    /// Offsets of saved registers are written in units of the CIE's data alignment (-8 on x86-64).
    fn factor(self: *Machine, n: i64) Error!i64 {
        return std.math.mul(i64, n, self.cie.data_align) catch return error.Malformed;
    }

    fn setRule(self: *Machine, reg: u64, rule: Rule) void {
        if (reg < num_regs) self.row.rules[@intCast(reg)] = rule;
    }

    fn restore(self: *Machine, reg: u64) void {
        if (reg < num_regs) self.row.rules[@intCast(reg)] = self.initial.rules[@intCast(reg)];
    }

    fn remember(self: *Machine) Error!void {
        if (self.depth == max_saved) return error.Malformed;
        self.saved[self.depth] = self.row;
        self.depth += 1;
    }

    fn recall(self: *Machine) Error!void {
        if (self.depth == 0) return error.Malformed;
        self.depth -= 1;
        self.row = self.saved[self.depth];
    }
};

// ------------------------------------------------------------------ as text

pub fn regName(reg: u64) []const u8 {
    if (reg >= num_regs) return "?";
    return reg_names[@intCast(reg)];
}

fn writeSigned(w: *std.Io.Writer, value: i64) !void {
    if (value >= 0) try w.writeAll("+");
    try w.print("{d}", .{value});
}

/// The way readelf writes it: "rsp+8", "rbp+16", "exp".
pub fn writeCfa(w: *std.Io.Writer, cfa: Cfa) !void {
    switch (cfa) {
        .unset => try w.writeAll("-"),
        .register => |c| {
            try w.writeAll(regName(c.reg));
            try writeSigned(w, c.offset);
        },
        .expression => try w.writeAll("exp"),
    }
}

/// The way readelf writes it: "c-8" (saved at CFA-8), "u" (lost), "s" (unchanged), "v+8",
/// a register name, "exp", "vexp". "-" is ours: no instruction says anything about it.
pub fn writeRule(w: *std.Io.Writer, rule: Rule) !void {
    switch (rule) {
        .unspecified => try w.writeAll("-"),
        .undef => try w.writeAll("u"),
        .same => try w.writeAll("s"),
        .offset => |n| {
            try w.writeAll("c");
            try writeSigned(w, n);
        },
        .val_offset => |n| {
            try w.writeAll("v");
            try writeSigned(w, n);
        },
        .register => |r| try w.writeAll(regName(r)),
        .expression => try w.writeAll("exp"),
        .val_expression => try w.writeAll("vexp"),
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// The starting rules gcc and clang give every x86-64 function: the CFA is rsp+8 and the
/// return address is stored at CFA-8.
const std_cie = [_]u8{ 0x0c, 0x07, 0x08, 0x90, 0x01 };

fn testFde(cie_program: []const u8, program: []const u8, begin: u64, end: u64) ehframe.Fde {
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
            .instructions = cie_program,
        },
        .instructions = program,
    };
}

fn expectCfa(row: Row, reg: u64, offset: i64) !void {
    switch (row.cfa) {
        .register => |c| {
            try testing.expectEqual(reg, c.reg);
            try testing.expectEqual(offset, c.offset);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectOffset(rule: Rule, offset: i64) !void {
    switch (rule) {
        .offset => |n| try testing.expectEqual(offset, n),
        else => return error.TestUnexpectedResult,
    }
}

fn expectTag(rule: Rule, tag: std.meta.Tag(Rule)) !void {
    try testing.expectEqual(tag, std.meta.activeTag(rule));
}

fn collect(fde: ehframe.Fde, out: []Entry) !usize {
    var it = try rows(fde);
    var n: usize = 0;
    while (try it.next()) |entry| {
        out[n] = entry;
        n += 1;
    }
    return n;
}

test "a function with a frame pointer: the rows follow push, mov and pop" {
    // advance 1; def_cfa_offset 16; rbp saved at CFA-16; advance 3; def_cfa_register rbp;
    // advance 12; def_cfa rsp+8; restore rbp
    const program = [_]u8{ 0x41, 0x0e, 0x10, 0x86, 0x02, 0x43, 0x0d, 0x06, 0x4c, 0x0c, 0x07, 0x08, 0xc6 };
    const fde = testFde(&std_cie, &program, 0x1000, 0x1020);
    var out: [8]Entry = undefined;
    const n = try collect(fde, &out);
    try testing.expectEqual(@as(usize, 4), n);

    try testing.expectEqual(@as(u64, 0x1000), out[0].start);
    try testing.expectEqual(@as(u64, 0x1001), out[0].end);
    try expectCfa(out[0].row, 7, 8);
    try expectOffset(out[0].row.rules[reg_ra], -8);
    try expectTag(out[0].row.rules[reg_rbp], .unspecified);

    try testing.expectEqual(@as(u64, 0x1001), out[1].start);
    try testing.expectEqual(@as(u64, 0x1004), out[1].end);
    try expectCfa(out[1].row, 7, 16);
    try expectOffset(out[1].row.rules[reg_rbp], -16);

    try testing.expectEqual(@as(u64, 0x1004), out[2].start);
    try testing.expectEqual(@as(u64, 0x1010), out[2].end);
    try expectCfa(out[2].row, 6, 16);
    try expectOffset(out[2].row.rules[reg_rbp], -16);

    try testing.expectEqual(@as(u64, 0x1010), out[3].start);
    try testing.expectEqual(@as(u64, 0x1020), out[3].end);
    try expectCfa(out[3].row, 7, 8);
    try expectTag(out[3].row.rules[reg_rbp], .unspecified);
    try expectOffset(out[3].row.rules[reg_ra], -8);
}

test "rowAt finds the row of an address and nothing outside the function" {
    const program = [_]u8{ 0x41, 0x0e, 0x10, 0x86, 0x02, 0x43, 0x0d, 0x06, 0x4c, 0x0c, 0x07, 0x08, 0xc6 };
    const fde = testFde(&std_cie, &program, 0x1000, 0x1020);

    try expectCfa((try rowAt(fde, 0x1000)).?, 7, 8);
    try expectCfa((try rowAt(fde, 0x1001)).?, 7, 16);
    try expectCfa((try rowAt(fde, 0x1003)).?, 7, 16);
    try expectCfa((try rowAt(fde, 0x1004)).?, 6, 16);
    try expectCfa((try rowAt(fde, 0x100f)).?, 6, 16);
    try expectCfa((try rowAt(fde, 0x1010)).?, 7, 8);
    try expectCfa((try rowAt(fde, 0x101f)).?, 7, 8);
    try testing.expect((try rowAt(fde, 0x0fff)) == null);
    try testing.expect((try rowAt(fde, 0x1020)) == null);
}

test "remember_state and restore_state bring back earlier rules" {
    // advance 1; cfa+16; advance 1; remember; cfa+8; advance 1; restore
    const program = [_]u8{ 0x41, 0x0e, 0x10, 0x41, 0x0a, 0x0e, 0x08, 0x41, 0x0b };
    var out: [8]Entry = undefined;
    const n = try collect(testFde(&std_cie, &program, 0x1000, 0x1010), &out);
    try testing.expectEqual(@as(usize, 4), n);
    try expectCfa(out[0].row, 7, 8);
    try expectCfa(out[1].row, 7, 16);
    try expectCfa(out[2].row, 7, 8);
    try expectCfa(out[3].row, 7, 16);
    try testing.expectEqual(@as(u64, 0x1003), out[3].start);
    try testing.expectEqual(@as(u64, 0x1010), out[3].end);
}

test "undefined return address marks the outermost frame, and restore brings the CIE rule back" {
    const program = [_]u8{ 0x07, 0x10, 0x41, 0xd0 }; // undefined ra; advance 1; restore ra
    var out: [4]Entry = undefined;
    const n = try collect(testFde(&std_cie, &program, 0x1000, 0x1010), &out);
    try testing.expectEqual(@as(usize, 2), n);
    try expectTag(out[0].row.rules[reg_ra], .undef);
    try expectOffset(out[1].row.rules[reg_ra], -8);
}

test "expressions are kept as bytes, for the CFA and for registers" {
    const program = [_]u8{
        // def_cfa_expression: what PLT stubs use
        0x0f, 0x0b, 0x77, 0x08, 0x80, 0x00, 0x3f, 0x1a, 0x3b, 0x2a, 0x33, 0x24, 0x22,
        0x10, 0x06, 0x02, 0x77, 0x00, // expression: rbp is saved where this computes
        0x16, 0x03, 0x01, 0x30, // val_expression for rbx
    };
    const row = (try rowAt(testFde(&std_cie, &program, 0x1000, 0x1010), 0x1000)).?;

    switch (row.cfa) {
        .expression => |e| {
            try testing.expectEqual(@as(usize, 11), e.len);
            try testing.expectEqual(@as(u8, 0x77), e[0]);
            try testing.expectEqual(@as(u8, 0x22), e[10]);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (row.rules[reg_rbp]) {
        .expression => |e| try testing.expectEqualSlices(u8, &.{ 0x77, 0x00 }, e),
        else => return error.TestUnexpectedResult,
    }
    switch (row.rules[3]) {
        .val_expression => |e| try testing.expectEqualSlices(u8, &.{0x30}, e),
        else => return error.TestUnexpectedResult,
    }
}

test "offsets are factored by the data alignment, and the CFA offset in def_cfa is not" {
    const program = [_]u8{
        0x11, 0x03, 0x7e, // offset_extended_sf rbx, -2   -> +16
        0x14, 0x04, 0x03, // val_offset rsi, 3            -> -24
        0x15, 0x05, 0x7f, // val_offset_sf rdi, -1        -> +8
        0x05, 0x06, 0x02, // offset_extended rbp, 2       -> -16
        0x09, 0x0c, 0x03, // r12 is held in rbx
        0x08, 0x0d, // r13 is unchanged
        0x0c, 0x06, 0x20, // def_cfa rbp+32, not factored
    };
    const row = (try rowAt(testFde(&std_cie, &program, 0x1000, 0x1010), 0x1000)).?;

    try expectOffset(row.rules[3], 16);
    switch (row.rules[4]) {
        .val_offset => |n| try testing.expectEqual(@as(i64, -24), n),
        else => return error.TestUnexpectedResult,
    }
    switch (row.rules[5]) {
        .val_offset => |n| try testing.expectEqual(@as(i64, 8), n),
        else => return error.TestUnexpectedResult,
    }
    try expectOffset(row.rules[reg_rbp], -16);
    switch (row.rules[12]) {
        .register => |r| try testing.expectEqual(@as(u64, 3), r),
        else => return error.TestUnexpectedResult,
    }
    try expectTag(row.rules[13], .same);
    try expectCfa(row, 6, 32);

    // The signed forms of the CFA instructions.
    const signed = [_]u8{ 0x12, 0x07, 0x02, 0x13, 0x7f }; // def_cfa_sf rsp, 2 -> -16; def_cfa_offset_sf -1 -> +8
    try expectCfa((try rowAt(testFde(&std_cie, &signed, 0x1000, 0x1010), 0x1000)).?, 7, 8);
    try expectCfa((try rowAt(testFde(&std_cie, &.{ 0x12, 0x07, 0x02 }, 0x1000, 0x1010), 0x1000)).?, 7, -16);
}

test "the three advance encodings, and the code alignment" {
    const program = [_]u8{ 0x02, 0x05, 0x03, 0x00, 0x01, 0x04, 0x00, 0x00, 0x01, 0x00 };
    var out: [8]Entry = undefined;
    const n = try collect(testFde(&std_cie, &program, 0x1000, 0x30000), &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(u64, 0x1005), out[0].end);
    try testing.expectEqual(@as(u64, 0x1105), out[1].end); // 256 more
    try testing.expectEqual(@as(u64, 0x11105), out[2].end); // 65536 more
    try testing.expectEqual(@as(u64, 0x11105), out[3].start);
    try testing.expectEqual(@as(u64, 0x30000), out[3].end);

    // With a code alignment of 4, an advance of 2 moves by 8.
    var fde = testFde(&std_cie, &.{ 0x42, 0x0e, 0x10 }, 0x1000, 0x1020);
    fde.cie.code_align = 4;
    const m = try collect(fde, &out);
    try testing.expectEqual(@as(usize, 2), m);
    try testing.expectEqual(@as(u64, 0x1008), out[0].end);
    try expectCfa(out[1].row, 7, 16);
}

test "an advance past the end of the function is cut at the end, and empty ranges have no rows" {
    var out: [4]Entry = undefined;
    const n = try collect(testFde(&std_cie, &.{ 0x44, 0x0e, 0x10 }, 0x1000, 0x1002), &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u64, 0x1000), out[0].start);
    try testing.expectEqual(@as(u64, 0x1002), out[0].end);

    try testing.expectEqual(@as(usize, 0), try collect(testFde(&std_cie, &.{0x00}, 0x1000, 0x1000), &out));
}

test "rules for registers beyond the ones that matter are read and ignored" {
    const row = (try rowAt(testFde(&std_cie, &.{ 0x05, 0x14, 0x01 }, 0x1000, 0x1010), 0x1000)).?; // register 20
    try expectOffset(row.rules[reg_ra], -8);
    try expectCfa(row, 7, 8);
}

test "broken programs give errors" {
    var it = try rows(testFde(&std_cie, &.{0x0b}, 0x1000, 0x1010)); // restore_state with nothing saved
    try testing.expectError(error.Malformed, it.next());

    it = try rows(testFde(&std_cie, &.{ 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a }, 0x1000, 0x1010));
    try testing.expectError(error.Malformed, it.next()); // 9 remembers, the limit is 8

    it = try rows(testFde(&std_cie, &.{ 0x0f, 0x01, 0x30, 0x0e, 0x10 }, 0x1000, 0x1010));
    try testing.expectError(error.Malformed, it.next()); // an offset for a CFA that is an expression

    it = try rows(testFde(&.{}, &.{ 0x0d, 0x06 }, 0x1000, 0x1010));
    try testing.expectError(error.Malformed, it.next()); // a register for a CFA that was never set

    it = try rows(testFde(&std_cie, &.{0x30}, 0x1000, 0x1010));
    try testing.expectError(error.Unsupported, it.next());
    it = try rows(testFde(&std_cie, &.{0x01}, 0x1000, 0x1010)); // set_loc
    try testing.expectError(error.Unsupported, it.next());

    it = try rows(testFde(&std_cie, &.{0x0e}, 0x1000, 0x1010));
    try testing.expectError(error.Truncated, it.next()); // an operand is missing
    it = try rows(testFde(&std_cie, &.{ 0x0f, 0x05, 0x01 }, 0x1000, 0x1010));
    try testing.expectError(error.Truncated, it.next()); // a block longer than the program

    // A CIE that moves the location, and an offset that does not fit.
    try testing.expectError(error.Malformed, rows(testFde(&.{0x41}, &.{}, 0x1000, 0x1010)));
    const huge = [_]u8{ 0x0c, 0x07, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    it = try rows(testFde(&std_cie, &huge, 0x1000, 0x1010));
    try testing.expectError(error.Malformed, it.next());
}

fn expectCfaText(expected: []const u8, cfa: Cfa) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeCfa(&aw.writer, cfa);
    try testing.expectEqualStrings(expected, aw.written());
}

fn expectRuleText(expected: []const u8, rule: Rule) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeRule(&aw.writer, rule);
    try testing.expectEqualStrings(expected, aw.written());
}

test "rows are written the way readelf writes them" {
    try expectCfaText("rsp+8", .{ .register = .{ .reg = 7, .offset = 8 } });
    try expectCfaText("rbp+16", .{ .register = .{ .reg = 6, .offset = 16 } });
    try expectCfaText("r10+0", .{ .register = .{ .reg = 10, .offset = 0 } });
    try expectCfaText("rsp-8", .{ .register = .{ .reg = 7, .offset = -8 } });
    try expectCfaText("exp", .{ .expression = &.{0x77} });
    try expectCfaText("-", .unset);

    try expectRuleText("c-8", .{ .offset = -8 });
    try expectRuleText("c+16", .{ .offset = 16 });
    try expectRuleText("v-24", .{ .val_offset = -24 });
    try expectRuleText("u", .undef);
    try expectRuleText("s", .same);
    try expectRuleText("-", .unspecified);
    try expectRuleText("rbx", .{ .register = 3 });
    try expectRuleText("exp", .{ .expression = &.{0x77} });
    try expectRuleText("vexp", .{ .val_expression = &.{0x30} });
}
