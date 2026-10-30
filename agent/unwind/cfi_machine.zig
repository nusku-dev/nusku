const std = @import("std");
const eh_frame = @import("eh_frame.zig");
const cfi = @import("cfi.zig");

/// DW_CFA_remember_state nesting. Compilers nest it once or twice; deeper is refused.
const saved_max = 8;

pub const Program = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn at_end(self: Program) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Program, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Truncated;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn int(self: *Program, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn uleb(self: *Program) !u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try self.int(u8);
            if (shift >= 64) return error.Malformed;
            if (shift == 63 and byte & 0x7e != 0) return error.Malformed;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn sleb(self: *Program) !i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try self.int(u8);
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
fn block(p: *Program) ![]const u8 {
    const len = std.math.cast(usize, try p.uleb()) orelse return error.Malformed;
    return p.take(len);
}

fn signed_from(n: u64) !i64 {
    return std.math.cast(i64, n) orelse return error.Malformed;
}

pub const Machine = struct {
    cie: eh_frame.Cie,
    /// The rules the CIE sets; what DW_CFA_restore goes back to.
    initial: cfi.Row = .{},
    row: cfi.Row = .{},
    saved: [saved_max]cfi.Row = undefined,
    depth: usize = 0,
    /// Where the current row starts.
    loc: u64,

    pub fn init(fde: eh_frame.Fde) !Machine {
        var m = Machine{ .cie = fde.cie, .loc = fde.pc_begin };
        var program = Program{ .bytes = fde.cie.instructions };
        // The CIE sets starting rules; it cannot move to another address.
        if (try m.run_to_advance(&program)) |_| return error.Malformed;
        m.initial = m.row;
        return m;
    }

    /// Executes instructions until one that moves the location, and returns the address it
    /// moves to; the current row is the one that holds below that address. Returns null when
    /// the program ends. Every instruction reads at least one byte, so this ends.
    pub fn run_to_advance(self: *Machine, p: *Program) !?u64 {
        while (!p.at_end()) {
            const op = try p.int(u8);
            // The top two bits pick a primary instruction, whose low six bits are its operand.
            switch (op & 0xc0) {
                0x40 => return try self.advance(op & 0x3f),
                0x80 => {
                    const n = try signed_from(try p.uleb());
                    self.rule_set(op & 0x3f, .{ .offset = try self.factor(n) });
                },
                0xc0 => self.restore(op & 0x3f),
                else => switch (op) {
                    0x00 => {}, // nop
                    0x02 => return try self.advance(try p.int(u8)),
                    0x03 => return try self.advance(try p.int(u16)),
                    0x04 => return try self.advance(try p.int(u32)),
                    0x0a => try self.remember(),
                    0x0b => try self.recall(),
                    0x0c, 0x0d, 0x0e, 0x0f, 0x12, 0x13 => try self.cfa_execute(op, p),
                    0x05...0x09, 0x10, 0x11, 0x14...0x16 => try self.rule_execute(op, p),
                    // GNU_args_size: matters for landing pads, not for the caller's frame.
                    0x2e => _ = try p.uleb(),
                    else => return error.Unsupported,
                },
            }
        }
        return null;
    }

    /// The instructions that change how the CFA is computed.
    fn cfa_execute(self: *Machine, op: u8, p: *Program) !void {
        switch (op) {
            0x0c => { // def_cfa: the offset is not factored
                const reg = try p.uleb();
                const offset = try signed_from(try p.uleb());
                self.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
            },
            0x0d => { // def_cfa_register
                const reg = try p.uleb();
                switch (self.row.cfa) {
                    .register => |*cfa| cfa.reg = reg,
                    else => return error.Malformed,
                }
            },
            0x0e => try self.cfa_offset_set(try signed_from(try p.uleb())), // def_cfa_offset
            0x0f => self.row.cfa = .{ .expression = try block(p) }, // def_cfa_expression
            0x12 => { // def_cfa_sf
                const reg = try p.uleb();
                const offset = try self.factor(try p.sleb());
                self.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
            },
            0x13 => try self.cfa_offset_set(try self.factor(try p.sleb())), // def_cfa_offset_sf
            else => unreachable, // run_to_advance sends only the instructions above.
        }
    }

    fn cfa_offset_set(self: *Machine, offset: i64) !void {
        switch (self.row.cfa) {
            .register => |*cfa| cfa.offset = offset,
            else => return error.Malformed,
        }
    }

    /// The instructions that change the rule of one register. Each starts with the register.
    fn rule_execute(self: *Machine, op: u8, p: *Program) !void {
        const reg = try p.uleb();
        switch (op) {
            0x05 => { // offset_extended
                const n = try signed_from(try p.uleb());
                self.rule_set(reg, .{ .offset = try self.factor(n) });
            },
            0x06 => self.restore(reg), // restore_extended
            0x07 => self.rule_set(reg, .undef),
            0x08 => self.rule_set(reg, .same),
            0x09 => self.rule_set(reg, .{ .register = try p.uleb() }),
            0x10 => self.rule_set(reg, .{ .expression = try block(p) }),
            0x11 => self.rule_set(reg, .{ .offset = try self.factor(try p.sleb()) }), // _sf
            0x14 => { // val_offset
                const n = try signed_from(try p.uleb());
                self.rule_set(reg, .{ .val_offset = try self.factor(n) });
            },
            0x15 => self.rule_set(reg, .{ .val_offset = try self.factor(try p.sleb()) }), // _sf
            0x16 => self.rule_set(reg, .{ .val_expression = try block(p) }),
            else => unreachable, // run_to_advance sends only the instructions above.
        }
    }

    fn advance(self: *Machine, delta: u64) !u64 {
        const by = std.math.mul(u64, delta, self.cie.code_align) catch return error.Malformed;
        return std.math.add(u64, self.loc, by) catch return error.Malformed;
    }

    /// Offsets of saved registers are written in units of the CIE's data alignment (-8 on x86-64).
    fn factor(self: *Machine, n: i64) !i64 {
        return std.math.mul(i64, n, self.cie.data_align) catch return error.Malformed;
    }

    fn rule_set(self: *Machine, reg: u64, rule: cfi.Rule) void {
        if (reg < cfi.num_regs) self.row.rules[@intCast(reg)] = rule;
    }

    fn restore(self: *Machine, reg: u64) void {
        if (reg < cfi.num_regs) self.row.rules[@intCast(reg)] = self.initial.rules[@intCast(reg)];
    }

    fn remember(self: *Machine) !void {
        if (self.depth == saved_max) return error.Malformed;
        self.saved[self.depth] = self.row;
        self.depth += 1;
    }

    fn recall(self: *Machine) !void {
        if (self.depth == 0) return error.Malformed;
        self.depth -= 1;
        self.row = self.saved[self.depth];
    }
};
