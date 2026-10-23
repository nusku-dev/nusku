//! Follows a stack from the registers of its innermost frame to the outermost one. A frame is
//! followed with the unwind tables of its module when it has some, and with the frame pointer
//! chain when it has not.
const std = @import("std");
const cfi = @import("cfi.zig");
const ehframe = @import("ehframe.zig");
const frame = @import("frame.zig");
const module = @import("module.zig");

/// Why the walk ended. Only `end` means the whole stack was found.
pub const Stop = enum {
    /// The outermost frame was reached: its return address is undefined or zero, or a frame
    /// pointer chain ended with a zero.
    end,
    /// The output was full.
    truncated,
    /// The innermost address is in no executable mapping we know of (generated code, for example).
    no_module,
    /// A module with unwind tables covers the address, but none of its functions do, and there
    /// is no frame pointer to fall back on.
    no_function,
    /// A rule or an expression could not be followed.
    unsupported,
    /// A rule or a frame pointer pointed outside the stack snapshot.
    outside_stack,
    /// The stack pointer did not move towards higher addresses, which a real stack always does.
    stuck,
    /// A return address is in no executable mapping, so it is not a return address. Typical when
    /// a frame pointer register holds data. The address is not in the output.
    invalid_address,
    /// A frame pointer is below the stack pointer, or not aligned.
    bad_frame_pointer,
};

pub const Result = struct {
    /// How many addresses were written to the output.
    count: usize,
    stop: Stop,
    /// How many frames were left through the frame pointer chain and not through tables. These
    /// are the steps that can be wrong for a function that has no frame pointer.
    fp_steps: usize = 0,
    /// How many frames were recovered by reading the top of the stack: the caller of a leaf
    /// function that has no frame, which the frame pointer chain would have skipped.
    repairs: usize = 0,
};

pub const Options = struct {
    /// True if the innermost pc is a return address and not the instruction that was running:
    /// a sample taken while the process was in a system call.
    innermost_is_return_address: bool = false,
    /// Look at the top of the stack for the caller of the innermost function when there are no
    /// tables for it. See `leafCaller`.
    leaf_repair: bool = false,
};

const Step = union(enum) { caller: frame.Frame, outermost, stop: Stop };

/// After a frame pointer step the chain tells nothing about the other registers.
const fp_known: u32 = (1 << cfi.reg_rbp) | (1 << cfi.reg_rsp) | (1 << cfi.reg_ra);

pub fn walk(modules: []const module.Module, start: frame.Frame, stack: frame.Stack, out: []u64, options: Options) Result {
    var f = start;
    var n: usize = 0;
    var fp_steps: usize = 0;
    var repairs: usize = 0;
    // The pc of an instruction that was running is looked up as it is. A return address points
    // just after a call, which can already be the next function, so it is looked up one byte earlier.
    var exact = !options.innermost_is_return_address;

    while (true) {
        if (n == out.len) return finish(n, fp_steps, repairs, .truncated);

        const at = if (exact) f.pc() else f.pc() -% 1;
        const found = moduleOf(modules, at);
        // The innermost pc is where the thread really was, so it is kept even when it is in no
        // known code. Every other address has to be a return address, which points into code.
        if (found == null and n > 0) return finish(n, fp_steps, repairs, .invalid_address);
        out[n] = f.pc();
        n += 1;
        const mod = found orelse return finish(n, fp_steps, repairs, .no_module);

        var fde: ?ehframe.Fde = null;
        if (mod.has_unwind) fde = mod.find(at);

        var used_frame_pointer = false;
        var repaired = false;
        const step: Step = if (fde) |entry| tableStep(mod, entry, at, f, stack) else blk: {
            if (options.leaf_repair and n == 1) {
                if (leafCaller(modules, mod, f, stack, at)) |caller| {
                    repaired = true;
                    break :blk .{ .caller = caller };
                }
            }
            // A function the tables do not cover. With a zero frame pointer there is nothing to follow.
            if (mod.has_unwind and f.regs[cfi.reg_rbp] == 0) break :blk .{ .stop = .no_function };
            used_frame_pointer = true;
            break :blk framePointerStep(f, stack);
        };

        switch (step) {
            .stop => |reason| return finish(n, fp_steps, repairs, reason),
            .outermost => return finish(n, fp_steps, repairs, .end),
            .caller => |c| {
                if (c.pc() == 0) return finish(n, fp_steps, repairs, .end);
                if (c.sp() <= f.sp()) return finish(n, fp_steps, repairs, .stuck);
                if (used_frame_pointer) fp_steps += 1;
                if (repaired) repairs += 1;
                // Above a signal trampoline the saved pc is the interrupted instruction.
                exact = if (fde) |entry| entry.cie.signal_frame else false;
                f = c;
            },
        }
    }
}

fn finish(count: usize, fp_steps: usize, repairs: usize, stop: Stop) Result {
    return .{ .count = count, .stop = stop, .fp_steps = fp_steps, .repairs = repairs };
}

fn tableStep(mod: module.Module, fde: ehframe.Fde, at: u64, f: frame.Frame, stack: frame.Stack) Step {
    const found = cfi.rowAt(fde, at - mod.bias) catch return .{ .stop = .unsupported };
    const row = found orelse return .{ .stop = .no_function };
    const next = frame.unwindOne(row, f, stack) catch |err| return .{
        .stop = switch (err) {
            error.OutsideStack => .outside_stack,
            else => .unsupported,
        },
    };
    return switch (next) {
        .outermost => .outermost,
        .caller => |c| .{ .caller = c },
    };
}

/// The standard frame: the frame pointer points at the saved frame pointer of the caller,
/// and the return address is above it. Only right for a function that has set up its frame.
fn framePointerStep(f: frame.Frame, stack: frame.Stack) Step {
    if (f.known & (1 << cfi.reg_rbp) == 0) return .{ .stop = .unsupported };
    const fp = f.regs[cfi.reg_rbp];
    if (fp == 0) return .outermost; // the conventional end of a frame pointer chain
    // A real frame lies above the stack pointer, on an 8 byte boundary.
    if (fp < f.sp() or fp % 8 != 0 or fp > std.math.maxInt(u64) - 16) return .{ .stop = .bad_frame_pointer };

    const saved_rbp = stack.readU64(fp) orelse return .{ .stop = .outside_stack };
    const return_address = stack.readU64(fp + 8) orelse return .{ .stop = .outside_stack };

    var caller = f;
    caller.regs[cfi.reg_ra] = return_address;
    caller.regs[cfi.reg_rbp] = saved_rbp;
    caller.regs[cfi.reg_rsp] = fp + 16;
    caller.known = fp_known;
    return .{ .caller = caller };
}

/// How far before the pc the entry of the innermost function can be. Real functions are shorter
/// than this; the limit only keeps an unrelated call instruction from being accepted.
const max_function_span: u64 = 64 * 1024;

/// A function that has touched neither the stack pointer nor the frame pointer (a leaf without
/// a frame) has its return address on top of the stack, and the frame pointer chain steps over
/// its caller. This reads that word and accepts it only if it points into code, the 5 bytes
/// before it are a direct call (E8 and a 32 bit offset), and the call's target is at or before
/// the pc, in the same module, and not far from it: that call is then the one that entered the
/// function we are in. It is a heuristic, so it is only used where no tables exist.
fn leafCaller(modules: []const module.Module, mod: module.Module, f: frame.Frame, stack: frame.Stack, at: u64) ?frame.Frame {
    const word = stack.readU64(f.sp()) orelse return null;
    if (word < 5) return null;
    const caller_module = moduleOf(modules, word -% 1) orelse return null;
    const call = caller_module.codeAt(word - 5, 5) orelse return null;
    if (call[0] != 0xe8) return null;

    const rel: i32 = @bitCast(std.mem.readInt(u32, call[1..5], .little));
    const target = word +% @as(u64, @bitCast(@as(i64, rel)));
    if (!mod.contains(target)) return null;
    if (target > at or at - target >= max_function_span) return null;

    // The function did not touch the stack or the registers: only the return address is consumed.
    var caller = f;
    caller.regs[cfi.reg_ra] = word;
    caller.regs[cfi.reg_rsp] = f.sp() + 8;
    return caller;
}

fn moduleOf(modules: []const module.Module, pc: u64) ?module.Module {
    for (modules) |m| {
        if (m.contains(pc)) return m;
    }
    return null;
}
// ------------------------------------------------------------------ tests

const testing = std.testing;

/// The starting rules gcc and clang give every x86-64 function: the CFA is rsp+8 and the
/// return address is stored at CFA-8.
const std_cie = [_]u8{ 0x0c, 0x07, 0x08, 0x90, 0x01 };

fn makeFde(begin: u64, end: u64, program: []const u8, signal: bool) ehframe.Fde {
    return .{
        .pc_begin = begin,
        .pc_end = end,
        .cie = .{
            .offset = 0,
            .code_align = 1,
            .data_align = -8,
            .ra_register = 16,
            .fde_encoding = 0x1b,
            .signal_frame = signal,
            .has_augmentation = true,
            .instructions = &std_cie,
        },
        .instructions = program,
    };
}

fn startFrame(pc: u64, sp: u64, rbp: u64) frame.Frame {
    var f = frame.Frame{ .regs = [_]u64{0} ** frame.num_regs };
    f.regs[cfi.reg_ra] = pc;
    f.regs[cfi.reg_rsp] = sp;
    f.regs[cfi.reg_rbp] = rbp;
    return f;
}

fn putWord(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

// A frameless leaf A, called by B which keeps a frame pointer, called by C which is outermost.
const prologue = [_]u8{ 0x41, 0x0e, 0x10, 0x86, 0x02, 0x43, 0x0d, 0x06 }; // push rbp; mov rbp, rsp
const outermost = [_]u8{ 0x07, 0x10 };
const chain_fdes = [_]ehframe.Fde{
    makeFde(0x1000, 0x1020, &.{}, false),
    makeFde(0x2000, 0x2040, &prologue, false),
    makeFde(0x3000, 0x3040, &outermost, false),
};

fn chainStack(mem: *[0x40]u8) frame.Stack {
    @memset(mem, 0);
    putWord(mem, 0x00, 0x2025); // A's return address, on top of the stack
    putWord(mem, 0x28, 0x3015); // B's return address, at CFA-8
    putWord(mem, 0x20, 0x7050); // B's saved rbp, at CFA-16
    return .{ .base = 0x7000, .bytes = mem };
}

test "a frameless leaf, a function with a frame pointer, and the outermost function" {
    var mem: [0x40]u8 = undefined;
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &chain_fdes }};
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), chainStack(&mem), &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(@as(u64, 0x1010), out[0]);
    try testing.expectEqual(@as(u64, 0x2025), out[1]);
    try testing.expectEqual(@as(u64, 0x3015), out[2]);
}

test "a frame pointer register holding garbage does not matter when the row does not use it" {
    // A uses the stack pointer for its CFA and saved rbp in its frame. rbp now holds data.
    const program = [_]u8{ 0x0e, 0x20, 0x86, 0x02 };
    const fdes = [_]ehframe.Fde{
        makeFde(0x1000, 0x1100, &program, false),
        makeFde(0x2000, 0x2040, &.{}, false),
    };
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &fdes }};

    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x18, 0x2025); // A's return address, at CFA-8 (the CFA is 0x7020)
    putWord(&mem, 0x10, 0x7050); // the caller's rbp
    // B's return address is on top of the stack when B is entered: zero, so the walk ends.
    var out: [8]u64 = undefined;
    const r = walk(&modules, startFrame(0x1010, 0x7000, 0xe9b5dba5b5c0fbcf), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expectEqual(@as(u64, 0x2025), out[1]);
}

test "the address above a signal trampoline is looked up as it is, not one byte earlier" {
    var mem = [_]u8{0} ** 0x20;
    putWord(&mem, 0x00, 0x2000); // the trampoline returns to the start of B, the interrupted instruction
    var out: [8]u64 = undefined;

    const signal_fdes = [_]ehframe.Fde{
        makeFde(0x2000, 0x2010, &.{}, false),
        makeFde(0x3000, 0x3010, &.{}, true),
    };
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &signal_fdes }};
    const r = walk(&modules, startFrame(0x3005, 0x7000, 0), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop); // B found at 0x2000, and its return address is zero
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expectEqual(@as(u64, 0x2000), out[1]);

    // The same stack, but the function below is not a signal trampoline: 0x1fff is in no function.
    const plain_fdes = [_]ehframe.Fde{
        makeFde(0x2000, 0x2010, &.{}, false),
        makeFde(0x3000, 0x3010, &.{}, false),
    };
    const plain = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &plain_fdes }};
    const p = walk(&plain, startFrame(0x3005, 0x7000, 0), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.no_function, p.stop);
    try testing.expectEqual(@as(usize, 2), p.count);
}

test "a sample taken inside a system call has a return address as its innermost pc" {
    const fdes = [_]ehframe.Fde{
        makeFde(0x1000, 0x1010, &.{}, false),
        makeFde(0x2000, 0x2010, &.{}, false),
    };
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &fdes }};
    var mem = [_]u8{0} ** 0x20;
    var out: [4]u64 = undefined;

    // pc 0x2000 is the instruction after the syscall at the end of the function before it.
    const as_return = walk(&modules, startFrame(0x2000, 0x7000, 0), .{ .base = 0x7000, .bytes = &mem }, &out, .{ .innermost_is_return_address = true });
    try testing.expectEqual(Stop.no_function, as_return.stop); // 0x1fff is in the gap between the functions

    const exact = walk(&modules, startFrame(0x2000, 0x7000, 0), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, exact.stop); // the return address read from the stack is zero
}

test "the load bias is applied to modules and to the rows" {
    // The same chain, but loaded at +0x500000.
    var mem: [0x40]u8 = undefined;
    _ = chainStack(&mem);
    putWord(&mem, 0x00, 0x502025);
    putWord(&mem, 0x28, 0x503015);
    const modules = [_]module.Module{.{ .start = 0x501000, .end = 0x504000, .bias = 0x500000, .fdes = &chain_fdes }};
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x501010, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(@as(u64, 0x503015), out[2]);
}

test "the reasons a walk stops before the end" {
    var mem: [0x40]u8 = undefined;
    const stack = chainStack(&mem);
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &chain_fdes }};
    var out: [8]u64 = undefined;

    // No module covers the first address.
    var r = walk(&modules, startFrame(0x9000, 0x7000, 0), stack, &out, .{});
    try testing.expectEqual(Stop.no_module, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);

    // A module covers it, but no function does.
    r = walk(&modules, startFrame(0x2800, 0x7000, 0), stack, &out, .{});
    try testing.expectEqual(Stop.no_function, r.stop);

    // The output is full.
    r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), stack, out[0..2], .{});
    try testing.expectEqual(Stop.truncated, r.stop);
    try testing.expectEqual(@as(usize, 2), r.count);
    r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), stack, out[0..0], .{});
    try testing.expectEqual(Stop.truncated, r.stop);
    try testing.expectEqual(@as(usize, 0), r.count);

    // The stack snapshot is too short to hold the return address.
    r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = mem[0..4] }, &out, .{});
    try testing.expectEqual(Stop.outside_stack, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);
}

test "a row that stands still, and a row that cannot be followed" {
    var big = [_]u8{0} ** 0x200;
    putWord(&big, 0xf8, 0x1010); // at 0x6ff8, so the CFA 0x7000 gives a return address
    var out: [8]u64 = undefined;

    // The CFA equals the stack pointer, so the caller's stack pointer does not move up.
    const stuck_fdes = [_]ehframe.Fde{makeFde(0x1000, 0x1100, &.{ 0x0c, 0x07, 0x00 }, false)};
    const stuck = [_]module.Module{.{ .start = 0x1000, .end = 0x2000, .bias = 0, .fdes = &stuck_fdes }};
    var r = walk(&stuck, startFrame(0x1010, 0x7000, 0), .{ .base = 0x6f00, .bytes = &big }, &out, .{});
    try testing.expectEqual(Stop.stuck, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);

    // A CFA taken from a register this unwinder does not know.
    const odd_fdes = [_]ehframe.Fde{makeFde(0x1000, 0x1100, &.{ 0x0c, 0x14, 0x08 }, false)};
    const odd = [_]module.Module{.{ .start = 0x1000, .end = 0x2000, .bias = 0, .fdes = &odd_fdes }};
    r = walk(&odd, startFrame(0x1010, 0x7000, 0), .{ .base = 0x6f00, .bytes = &big }, &out, .{});
    try testing.expectEqual(Stop.unsupported, r.stop);
}

test "a module without unwind tables is followed through the frame pointer chain" {
    var mem = [_]u8{0} ** 0x80;
    putWord(&mem, 0x20, 0x7050); // the first frame: the caller's frame pointer ...
    putWord(&mem, 0x28, 0x2025); // ... and the return address
    putWord(&mem, 0x50, 0); // the second frame: the chain ends here ...
    putWord(&mem, 0x58, 0x3015); // ... after this return address
    const modules = [_]module.Module{module.Module.withoutUnwindInfo(0x1000, 0x4000)};
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(@as(u64, 0x1010), out[0]);
    try testing.expectEqual(@as(u64, 0x2025), out[1]);
    try testing.expectEqual(@as(u64, 0x3015), out[2]);
    try testing.expectEqual(@as(usize, 2), r.fp_steps);
}

test "tables are used where there are some and frame pointers where there are not" {
    // The first function has a table and is a frameless leaf. Its caller is in a mapping without one.
    const fdes = [_]ehframe.Fde{makeFde(0x1000, 0x1020, &.{}, false)};
    const modules = [_]module.Module{
        .{ .start = 0x1000, .end = 0x2000, .bias = 0, .fdes = &fdes },
        module.Module.withoutUnwindInfo(0x2000, 0x4000),
    };
    var mem = [_]u8{0} ** 0x80;
    putWord(&mem, 0x00, 0x2025); // the leaf's return address, on top of the stack
    putWord(&mem, 0x50, 0); // the caller's frame: the chain ends here ...
    putWord(&mem, 0x58, 0x3015); // ... after its return address
    var out: [8]u64 = undefined;

    // rbp is the caller's frame pointer, which the leaf never touched.
    const r = walk(&modules, startFrame(0x1010, 0x7000, 0x7050), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 3), r.count);
    try testing.expectEqual(@as(u64, 0x2025), out[1]);
    try testing.expectEqual(@as(u64, 0x3015), out[2]);
    try testing.expectEqual(@as(usize, 1), r.fp_steps);
}

test "a frame pointer holding data gives an address that is not code, and the walk stops before it" {
    var mem = [_]u8{0} ** 0x80;
    putWord(&mem, 0x20, 0x7050);
    putWord(&mem, 0x28, 0xe9b5dba5b5c0fbcf); // what the assembly routine left there
    const modules = [_]module.Module{module.Module.withoutUnwindInfo(0x1000, 0x4000)};
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x1010, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.invalid_address, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count); // the garbage is not in the output
    try testing.expectEqual(@as(u64, 0x1010), out[0]);
}

test "a frame pointer below the stack pointer, unaligned, beyond the snapshot or absurd is not followed" {
    var mem = [_]u8{0} ** 0x40;
    const modules = [_]module.Module{module.Module.withoutUnwindInfo(0x1000, 0x4000)};
    var out: [8]u64 = undefined;
    const stack = frame.Stack{ .base = 0x7000, .bytes = &mem };

    var r = walk(&modules, startFrame(0x1010, 0x7000, 0x6ff0), stack, &out, .{});
    try testing.expectEqual(Stop.bad_frame_pointer, r.stop);
    r = walk(&modules, startFrame(0x1010, 0x7000, 0x7011), stack, &out, .{});
    try testing.expectEqual(Stop.bad_frame_pointer, r.stop);
    r = walk(&modules, startFrame(0x1010, 0x7000, 0x9000), stack, &out, .{});
    try testing.expectEqual(Stop.outside_stack, r.stop);
    r = walk(&modules, startFrame(0x1010, 0x7000, std.math.maxInt(u64) - 7), stack, &out, .{});
    try testing.expectEqual(Stop.bad_frame_pointer, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);
}

test "a function the tables do not cover is followed through the frame pointer, unless there is none" {
    const fdes = [_]ehframe.Fde{makeFde(0x1000, 0x1010, &.{}, false)};
    const modules = [_]module.Module{.{ .start = 0x1000, .end = 0x4000, .bias = 0, .fdes = &fdes }};
    var mem = [_]u8{0} ** 0x80;
    putWord(&mem, 0x20, 0x7050);
    putWord(&mem, 0x28, 0x1005); // returns into the covered function, whose own return address is zero
    var out: [8]u64 = undefined;

    // pc 0x2000 is in the module but no function covers it, and rbp holds a real frame.
    var r = walk(&modules, startFrame(0x2000, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expectEqual(@as(u64, 0x1005), out[1]);
    try testing.expectEqual(@as(usize, 1), r.fp_steps);

    // The same address with a zero frame pointer: nothing to follow.
    r = walk(&modules, startFrame(0x2000, 0x7000, 0), .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.no_function, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);
}

test "registers other than the stack and frame pointers are unknown after a frame pointer step" {
    // After a frame pointer step into a function with a table whose CFA is based on rbx,
    // the walk fails loudly and does not use a stale rbx.
    const program = [_]u8{ 0x0c, 0x03, 0x10 }; // def_cfa rbx+16
    const fdes = [_]ehframe.Fde{makeFde(0x1000, 0x1100, &program, false)};
    const modules = [_]module.Module{
        .{ .start = 0x1000, .end = 0x2000, .bias = 0, .fdes = &fdes },
        module.Module.withoutUnwindInfo(0x2000, 0x4000),
    };
    var mem = [_]u8{0} ** 0x80;
    putWord(&mem, 0x20, 0x7050);
    putWord(&mem, 0x28, 0x1005); // the return address of a function in the first module
    var out: [8]u64 = undefined;

    var f = startFrame(0x2010, 0x7000, 0x7020);
    f.regs[3] = 0x7000; // a real-looking rbx, which the frame pointer chain cannot vouch for
    const r = walk(&modules, f, .{ .base = 0x7000, .bytes = &mem }, &out, .{});
    try testing.expectEqual(Stop.unsupported, r.stop);
    try testing.expectEqual(@as(usize, 2), r.count);
}

/// A module of code with no unwind information whose bytes are known. A function around 0x1100
/// calls the leaf at 0x1800 with a direct call at 0x1120; the call's return address is 0x1125.
fn leafImage(image: []u8) module.Module {
    @memset(image, 0);
    image[0x120] = 0xe8;
    std.mem.writeInt(i32, image[0x121..][0..4], @intCast(@as(i64, 0x1800) - 0x1125), .little);
    return .{
        .start = 0x1000,
        .end = 0x1000 + @as(u64, image.len),
        .bias = 0,
        .fdes = &.{},
        .has_unwind = false,
        .image = image,
        .seg_offset = 0,
        .seg_vaddr = 0x1000,
        .seg_size = image.len,
    };
}

/// The stack of the leaf: its return address on top, then the frame of its caller, whose saved
/// frame pointer is 0 (the end of the chain) and whose own return address is 0x1205.
fn leafStack(mem: *[0x40]u8) frame.Stack {
    @memset(mem, 0);
    putWord(mem, 0x00, 0x1125);
    putWord(mem, 0x28, 0x1205);
    return .{ .base = 0x7000, .bytes = mem };
}

test "a frameless leaf gets its caller from the top of the stack, when asked to" {
    var image: [0x1000]u8 = undefined;
    const modules = [_]module.Module{leafImage(&image)};
    var mem: [0x40]u8 = undefined;
    const stack = leafStack(&mem);
    var out: [8]u64 = undefined;

    // The frame pointer chain steps over the caller of the leaf.
    const plain = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), stack, &out, .{});
    try testing.expectEqual(Stop.end, plain.stop);
    try testing.expectEqual(@as(usize, 2), plain.count);
    try testing.expectEqual(@as(u64, 0x1205), out[1]);

    const repaired = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), stack, &out, .{ .leaf_repair = true });
    try testing.expectEqual(Stop.end, repaired.stop);
    try testing.expectEqual(@as(usize, 3), repaired.count);
    try testing.expectEqual(@as(u64, 0x1810), out[0]);
    try testing.expectEqual(@as(u64, 0x1125), out[1]);
    try testing.expectEqual(@as(u64, 0x1205), out[2]);
    try testing.expectEqual(@as(usize, 1), repaired.repairs);
    try testing.expectEqual(@as(usize, 1), repaired.fp_steps);
}

test "the word on top of the stack is refused unless it follows a call into the function we are in" {
    var image: [0x1000]u8 = undefined;
    var mem: [0x40]u8 = undefined;
    var out: [8]u64 = undefined;
    const options = Options{ .leaf_repair = true };

    // Not a call instruction.
    var modules = [_]module.Module{leafImage(&image)};
    image[0x120] = 0x90;
    var r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), leafStack(&mem), &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);
    try testing.expectEqual(@as(usize, 2), r.count);

    // A call whose target lies after the pc.
    modules = [_]module.Module{leafImage(&image)};
    std.mem.writeInt(i32, image[0x121..][0..4], @intCast(@as(i64, 0x1900) - 0x1125), .little);
    r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), leafStack(&mem), &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);

    // A call whose target is outside the module.
    modules = [_]module.Module{leafImage(&image)};
    std.mem.writeInt(i32, image[0x121..][0..4], @intCast(@as(i64, 0x9000) - 0x1125), .little);
    r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), leafStack(&mem), &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);

    // A word that points into no code.
    modules = [_]module.Module{leafImage(&image)};
    const stack = leafStack(&mem);
    putWord(&mem, 0x00, 0x9000);
    r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), stack, &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);

    // A word whose return address is the first byte of the module: there is no call before it.
    putWord(&mem, 0x00, 0x1000);
    r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), stack, &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);

    // A snapshot too short to hold the word.
    r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), .{ .base = 0x7000, .bytes = mem[0..4] }, &out, options);
    try testing.expectEqual(@as(usize, 0), r.repairs);
    try testing.expectEqual(Stop.outside_stack, r.stop);
}

test "a call to a function that begins too far before the pc is refused" {
    const image = try testing.allocator.alloc(u8, 0x30000);
    defer testing.allocator.free(image);
    const modules = [_]module.Module{leafImage(image)};
    // The call at 0x1120 targets 0x1100, and the pc is at 0x20000, nearly 124 KB later.
    std.mem.writeInt(i32, image[0x121..][0..4], @intCast(@as(i64, 0x1100) - 0x1125), .little);
    var mem: [0x40]u8 = undefined;
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x20000, 0x7000, 0x7020), leafStack(&mem), &out, .{ .leaf_repair = true });
    try testing.expectEqual(@as(usize, 0), r.repairs);
}

test "the repair is for the innermost frame only, and never where tables exist" {
    // The same code, but the function has a table: the table is used and the stack top ignored.
    var image: [0x1000]u8 = undefined;
    var m = leafImage(&image);
    const fdes = [_]ehframe.Fde{makeFde(0x1800, 0x1820, &.{}, false)};
    m.fdes = &fdes;
    m.has_unwind = true;
    const modules = [_]module.Module{m};
    var mem: [0x40]u8 = undefined;
    var out: [8]u64 = undefined;

    const r = walk(&modules, startFrame(0x1810, 0x7000, 0x7020), leafStack(&mem), &out, .{ .leaf_repair = true });
    try testing.expectEqual(@as(usize, 0), r.repairs);
    try testing.expectEqual(@as(u64, 0x1125), out[1]); // the table says the same, since the leaf is frameless
}
