const std = @import("std");
const ehframe = @import("core/ehframe.zig");
const cfi = @import("core/cfi.zig");

const max_saved = 8;

pub const Program = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn atEnd(self: Program) bool {
        return self.pos >= self.bytes.len;
    }

    fn take(self: *Program, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Truncated;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn readU8(self: *Program) !u8 {
        return (try self.take(1))[0];
    }

    fn readU16(self: *Program) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn readU32(self: *Program) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn uleb(self: *Program) !u64 {
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

    fn sleb(self: *Program) !i64 {
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
fn block(p: *Program) ![]const u8 {
    const len = std.math.cast(usize, try p.uleb()) orelse return error.Malformed;
    return p.take(len);
}

fn toSigned(n: u64) !i64 {
    return std.math.cast(i64, n) orelse return error.Malformed;
}

pub const Machine = struct {
    cie: ehframe.Cie,
    /// The rules the CIE sets; what DW_CFA_restore goes back to.
    initial: cfi.Row = .{},
    row: cfi.Row = .{},
    saved: [max_saved]cfi.Row = undefined,
    depth: usize = 0,
    /// Where the current row starts.
    loc: u64,

    pub fn init(fde: ehframe.Fde) !Machine {
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
    pub fn runToAdvance(self: *Machine, p: *Program) !?u64 {
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

    fn advance(self: *Machine, delta: u64) !u64 {
        const by = std.math.mul(u64, delta, self.cie.code_align) catch return error.Malformed;
        return std.math.add(u64, self.loc, by) catch return error.Malformed;
    }

    /// Offsets of saved registers are written in units of the CIE's data alignment (-8 on x86-64).
    fn factor(self: *Machine, n: i64) !i64 {
        return std.math.mul(i64, n, self.cie.data_align) catch return error.Malformed;
    }

    fn setRule(self: *Machine, reg: u64, rule: cfi.Rule) void {
        if (reg < cfi.num_regs) self.row.rules[@intCast(reg)] = rule;
    }

    fn restore(self: *Machine, reg: u64) void {
        if (reg < cfi.num_regs) self.row.rules[@intCast(reg)] = self.initial.rules[@intCast(reg)];
    }

    fn remember(self: *Machine) !void {
        if (self.depth == max_saved) return error.Malformed;
        self.saved[self.depth] = self.row;
        self.depth += 1;
    }

    fn recall(self: *Machine) !void {
        if (self.depth == 0) return error.Malformed;
        self.depth -= 1;
        self.row = self.saved[self.depth];
    }
};
