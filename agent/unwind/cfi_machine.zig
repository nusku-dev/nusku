//! Runs the DWARF call frame instructions of a CIE and an FDE, one row at a time: the unwind
//! rule that holds over each range of addresses the FDE covers.

const std = @import("std");
const eh_frame = @import("../elf/elf.zig").eh_frame;
const cfi = @import("cfi.zig");

/// DW_CFA_remember_state nesting. Compilers nest it once or twice; deeper is refused.
const saved_max = 8;

pub const Program = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn at_end(program: Program) bool {
        return program.pos >= program.bytes.len;
    }

    fn take(program: *Program, n: usize) ![]const u8 {
        if (n > program.bytes.len - program.pos) return error.Truncated;
        const out = program.bytes[program.pos .. program.pos + n];
        program.pos += n;
        return out;
    }

    fn int(program: *Program, comptime T: type) !T {
        return std.mem.readInt(T, (try program.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn uleb(program: *Program) !u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const byte = try program.int(u8);
            if (shift >= 64) return error.Malformed;
            if (shift == 63 and byte & 0x7e != 0) return error.Malformed;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
            shift += 7;
        }
    }

    fn sleb(program: *Program) !i64 {
        var result: i64 = 0;
        var shift: u32 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try program.int(u8);
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
fn block(program: *Program) ![]const u8 {
    const len = std.math.cast(usize, try program.uleb()) orelse return error.Malformed;
    return program.take(len);
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
    pub fn run_to_advance(machine: *Machine, program: *Program) !?u64 {
        while (!program.at_end()) {
            const op = try program.int(u8);
            // The top two bits pick a primary instruction, whose low six bits are its operand.
            switch (op & 0xc0) {
                0x40 => return try machine.advance(op & 0x3f),
                0x80 => {
                    const n = try signed_from(try program.uleb());
                    machine.rule_set(op & 0x3f, .{ .offset = try machine.factor(n) });
                },
                0xc0 => machine.restore(op & 0x3f),
                else => switch (op) {
                    0x00 => {}, // nop
                    0x02 => return try machine.advance(try program.int(u8)),
                    0x03 => return try machine.advance(try program.int(u16)),
                    0x04 => return try machine.advance(try program.int(u32)),
                    0x0a => try machine.remember(),
                    0x0b => try machine.recall(),
                    0x0c, 0x0d, 0x0e, 0x0f, 0x12, 0x13 => try machine.cfa_execute(op, program),
                    0x05...0x09, 0x10, 0x11, 0x14...0x16 => try machine.rule_execute(op, program),
                    // GNU_args_size: matters for landing pads, not for the caller's frame.
                    0x2e => _ = try program.uleb(),
                    else => return error.Unsupported,
                },
            }
        }
        return null;
    }

    /// The instructions that change how the CFA is computed.
    fn cfa_execute(machine: *Machine, op: u8, program: *Program) !void {
        switch (op) {
            0x0c => { // def_cfa: the offset is not factored
                const reg = try program.uleb();
                const offset = try signed_from(try program.uleb());
                machine.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
            },
            0x0d => { // def_cfa_register
                const reg = try program.uleb();
                switch (machine.row.cfa) {
                    .register => |*cfa| cfa.reg = reg,
                    else => return error.Malformed,
                }
            },
            0x0e => { // def_cfa_offset
                try machine.cfa_offset_set(try signed_from(try program.uleb()));
            },
            0x0f => machine.row.cfa = .{ .expression = try block(program) }, // def_cfa_expression
            0x12 => { // def_cfa_sf
                const reg = try program.uleb();
                const offset = try machine.factor(try program.sleb());
                machine.row.cfa = .{ .register = .{ .reg = reg, .offset = offset } };
            },
            0x13 => { // def_cfa_offset_sf
                try machine.cfa_offset_set(try machine.factor(try program.sleb()));
            },
            else => unreachable, // run_to_advance sends only the instructions above.
        }
    }

    fn cfa_offset_set(machine: *Machine, offset: i64) !void {
        switch (machine.row.cfa) {
            .register => |*cfa| cfa.offset = offset,
            else => return error.Malformed,
        }
    }

    /// The instructions that change the rule of one register. Each starts with the register.
    fn rule_execute(machine: *Machine, op: u8, program: *Program) !void {
        const reg = try program.uleb();
        switch (op) {
            0x05 => { // offset_extended
                const n = try signed_from(try program.uleb());
                machine.rule_set(reg, .{ .offset = try machine.factor(n) });
            },
            0x06 => machine.restore(reg), // restore_extended
            0x07 => machine.rule_set(reg, .undef),
            0x08 => machine.rule_set(reg, .same),
            0x09 => machine.rule_set(reg, .{ .register = try program.uleb() }),
            0x10 => machine.rule_set(reg, .{ .expression = try block(program) }),
            0x11 => { // offset_extended_sf
                machine.rule_set(reg, .{ .offset = try machine.factor(try program.sleb()) });
            },
            0x14 => { // val_offset
                const n = try signed_from(try program.uleb());
                machine.rule_set(reg, .{ .val_offset = try machine.factor(n) });
            },
            0x15 => { // val_offset_sf
                machine.rule_set(reg, .{ .val_offset = try machine.factor(try program.sleb()) });
            },
            0x16 => machine.rule_set(reg, .{ .val_expression = try block(program) }),
            else => unreachable, // run_to_advance sends only the instructions above.
        }
    }

    fn advance(machine: *Machine, delta: u64) !u64 {
        const by = std.math.mul(u64, delta, machine.cie.code_align) catch return error.Malformed;
        return std.math.add(u64, machine.loc, by) catch return error.Malformed;
    }

    /// Offsets of saved registers are written in units of the CIE's data alignment (-8 on x86-64).
    fn factor(machine: *Machine, n: i64) !i64 {
        return std.math.mul(i64, n, machine.cie.data_align) catch return error.Malformed;
    }

    fn rule_set(machine: *Machine, reg: u64, rule: cfi.Rule) void {
        if (reg < cfi.num_regs) machine.row.rules[@intCast(reg)] = rule;
    }

    fn restore(machine: *Machine, reg: u64) void {
        if (reg >= cfi.num_regs) return;
        machine.row.rules[@intCast(reg)] = machine.initial.rules[@intCast(reg)];
    }

    fn remember(machine: *Machine) !void {
        if (machine.depth == saved_max) return error.Malformed;
        machine.saved[machine.depth] = machine.row;
        machine.depth += 1;
    }

    fn recall(machine: *Machine) !void {
        if (machine.depth == 0) return error.Malformed;
        machine.depth -= 1;
        machine.row = machine.saved[machine.depth];
    }
};
