//! The walk policy of `walk.zig`, over the compact tables and the process entry that the BPF
//! program uses. The BPF walk makes exactly these decisions, so a stack walked here and in the
//! kernel has to come out the same; this version is the one tests can run without privileges.
//!
//! Differences from `walk.zig`, on purpose for now: leaf repair only when `Options.code` is
//! given, no signal frames (after the
//! first frame the lookup is always one byte before the return address), and no tracking of
//! which registers are known (the compact rows turn anything unusual into `unsupported`).
const std = @import("std");
const compact = @import("compact.zig");
const frame = @import("frame.zig");
const procmap = @import("procmap.zig");
const tableset = @import("tableset.zig");

/// Why the walk ended. Only `end` means the whole stack was found. The numbers are shared with
/// the BPF program.
pub const Stop = enum(u8) {
    /// The outermost frame was reached: its return address is undefined or zero, or a frame
    /// pointer chain ended with a zero.
    end = 1,
    /// The output was full.
    truncated = 2,
    /// The innermost address is in no executable mapping we know of (generated code, for example).
    no_module = 3,
    /// A module with tables covers the address, but none of its functions do, and there is no
    /// frame pointer to fall back on.
    no_function = 4,
    /// A rule could not be followed.
    unsupported = 5,
    /// A rule or a frame pointer pointed outside the readable stack.
    outside_stack = 6,
    /// The stack pointer did not move towards higher addresses, which a real stack always does.
    stuck = 7,
    /// A return address is in no executable mapping, so it is not a return address. The address
    /// is not in the output.
    invalid_address = 8,
    /// A frame pointer is below the stack pointer, or not aligned.
    bad_frame_pointer = 9,
    /// Only the BPF program stops like this: its chain of tail calls ran out before the stack ended.
    chain = 10,
};

pub const Result = struct {
    /// How many addresses were written to the output.
    count: usize,
    stop: Stop,
    /// How many frames were left through the frame pointer chain and not through tables.
    fp_steps: usize = 0,
};

/// Bytes of code at `base`, for the checks that look at instructions.
pub const Code = struct {
    base: u64,
    bytes: []const u8,

    pub fn read(self: Code, addr: u64, len: usize) ?[]const u8 {
        if (addr < self.base) return null;
        const offset = addr - self.base;
        if (offset > self.bytes.len or self.bytes.len - offset < len) return null;
        const at: usize = @intCast(offset);
        return self.bytes[at..][0..len];
    }
};

pub const Options = struct {
    /// True if the innermost pc is a return address and not the instruction that was running:
    /// a sample taken while the process was in a system call.
    innermost_is_return_address: bool = false,
    /// Code bytes for the leaf repair. Without them the repair is off.
    code: ?Code = null,
};

const Step = union(enum) { caller: compact.Regs, end, stop: Stop };

pub fn walk(
    entry: *const procmap.ProcessEntry,
    set: *const tableset.TableSet,
    start: compact.Regs,
    stack: frame.Stack,
    out: []u64,
    options: Options,
) Result {
    var r = start;
    var n: usize = 0;
    var fp_steps: usize = 0;
    // The pc of an instruction that was running is looked up as it is. A return address points
    // just after a call, which can already be the next function, so it is looked up one byte earlier.
    var exact = !options.innermost_is_return_address;

    while (true) {
        if (n == out.len) return finish(n, fp_steps, .truncated);

        const at = if (exact) r.pc else r.pc -% 1;
        const mapping = procmap.find(entry, at);
        // The innermost pc is where the thread really was, so it is kept even when it is in no
        // known code. Every other address has to be a return address, which points into code.
        if (mapping == null and n > 0) return finish(n, fp_steps, .invalid_address);
        out[n] = r.pc;
        n += 1;
        const m = mapping orelse return finish(n, fp_steps, .no_module);

        var used_frame_pointer = false;
        const step: Step = blk: {
            if (m.module != procmap.no_module) {
                if (tableStep(set, m, at, r, stack)) |s| break :blk s;
                // Tables cover the module, but no function covers the address. For the first
                // frame, a frameless leaf without an entry still has its return address at sp.
                if (n == 1 and !options.innermost_is_return_address) {
                    if (options.code) |code| {
                        if (leafRepair(entry, m, r, stack, code)) |c| break :blk .{ .caller = c };
                    }
                }
                // Tables cover the module, but no function covers the address.
                if (r.bp == 0) break :blk .{ .stop = .no_function };
            }
            used_frame_pointer = true;
            break :blk framePointerStep(r, stack);
        };

        switch (step) {
            .stop => |reason| return finish(n, fp_steps, reason),
            .end => return finish(n, fp_steps, .end),
            .caller => |c| {
                if (c.pc == 0) return finish(n, fp_steps, .end);
                if (c.sp <= r.sp) return finish(n, fp_steps, .stuck);
                if (used_frame_pointer) fp_steps += 1;
                exact = false;
                r = c;
            },
        }
    }
}

fn finish(count: usize, fp_steps: usize, stop: Stop) Result {
    return .{ .count = count, .stop = stop, .fp_steps = fp_steps };
}

pub fn hashStack(frames: []const u64, stop: Stop, leaf_is_return: bool) u64 {
    return hashStackWithKernel(frames, &.{}, stop, leaf_is_return);
}

/// The hash of a stack that also has a kernel part. Without kernel frames it is `hashStack`.
pub fn hashStackWithKernel(frames: []const u64, kernel: []const u64, stop: Stop, leaf_is_return: bool) u64 {
    var h: u64 = 0;
    for (frames) |pc| h = mix(h ^ pc);
    for (kernel) |pc| h = mix(h ^ pc);
    return mix(h ^ ((@as(u64, @intFromEnum(stop)) << 1) | @intFromBool(leaf_is_return)));
}

fn mix(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Null when the tables have no function for the address, which is not an error: the frame
/// pointer may still lead on.
fn tableStep(set: *const tableset.TableSet, m: procmap.Mapping, at: u64, r: compact.Regs, stack: frame.Stack) ?Step {
    const row = set.find(m.module, at -% m.bias) orelse return null;
    const next = compact.unwind(row, r, stack) catch |err| switch (err) {
        error.NoFunction => return null,
        error.OutsideStack => return .{ .stop = .outside_stack },
        error.Unsupported => return .{ .stop = .unsupported },
    };
    return switch (next) {
        .end => .end,
        .caller => |c| .{ .caller = c },
    };
}

/// The standard frame: the frame pointer points at the saved frame pointer of the caller, and
/// the return address is above it. Only right for a function that has set up its frame.
fn framePointerStep(r: compact.Regs, stack: frame.Stack) Step {
    const fp = r.bp;
    if (fp == 0) return .end; // the conventional end of a frame pointer chain
    // A real frame lies above the stack pointer, on an 8 byte boundary.
    if (fp < r.sp or fp % 8 != 0 or fp > std.math.maxInt(u64) - 16) return .{ .stop = .bad_frame_pointer };
    const saved_bp = stack.readU64(fp) orelse return .{ .stop = .outside_stack };
    const return_address = stack.readU64(fp + 8) orelse return .{ .stop = .outside_stack };
    return .{ .caller = .{ .pc = return_address, .sp = fp + 16, .bp = saved_bp } };
}

const repair_max_distance: u64 = 64 * 1024;

/// For the first frame only, when no function covers pc: if the word at sp looks like the return
/// address of a direct call into a function that contains pc, take it as the caller. A frameless
/// leaf has not moved sp or rbp, so the caller is {pc = word, sp = sp + 8, bp unchanged}.
/// Every check has to hold, or the answer is null and the walk goes on as before.
fn leafRepair(entry: *const procmap.ProcessEntry, m: procmap.Mapping, r: compact.Regs, stack: frame.Stack, code: Code) ?compact.Regs {
    const w = stack.readU64(r.sp) orelse return null;
    if (w < 5) return null;
    // Like every return address, it has to point into code we know of.
    _ = procmap.find(entry, w -% 1) orelse return null;
    // The 5 bytes before it are `call rel32`.
    const call = code.read(w - 5, 5) orelse return null;
    if (call[0] != 0xe8) return null;
    const rel: i32 = @bitCast(std.mem.readInt(u32, call[1..5], .little));
    const target = w +% @as(u64, @bitCast(@as(i64, rel)));
    // The call went to a function in this module that starts at or before pc, not too far back.
    const tm = procmap.find(entry, target) orelse return null;
    if (tm.module != m.module) return null;
    if (target > r.pc or r.pc - target > repair_max_distance) return null;
    return .{ .pc = w, .sp = r.sp +% 8, .bp = r.bp };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const ehframe = @import("ehframe.zig");
const registry = @import("registry.zig");

/// The starting rules gcc and clang give every x86-64 function: the CFA is rsp+8 and the
/// return address is stored at CFA-8.
const std_cie = [_]u8{ 0x0c, 0x07, 0x08, 0x90, 0x01 };
const prologue = [_]u8{ 0x41, 0x0e, 0x10, 0x86, 0x02, 0x43, 0x0d, 0x06 }; // push rbp; mov rbp, rsp
const outermost = [_]u8{ 0x07, 0x10 }; // the return address is undefined

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

/// One mapping 0x1000..0x4000 with three functions (A 0x1000, a frameless leaf; B 0x2000, with a
/// frame pointer; C 0x3000, the outermost), gaps between them, and one mapping 0x5000..0x6000
/// that has no table.
const delta: u64 = 0x1000;

const Fixture = struct {
    set: tableset.TableSet,
    entry: procmap.ProcessEntry,

    fn init(allocator: std.mem.Allocator) !Fixture {
        const fdes = [_]ehframe.Fde{
            makeFde(0x1000, 0x1020, &.{}),
            makeFde(0x2000, 0x2040, &prologue),
            makeFde(0x3000, 0x3040, &outermost),
        };
        var table = try compact.build(allocator, &fdes);
        defer table.deinit(allocator);
        var set = tableset.TableSet.init(allocator, 1024, 8);
        errdefer set.deinit();
        const id = try set.add(table);
        try testing.expectEqual(@as(u64, 0), registry.biasOf(delta, 0x1000, 0));
        const inputs = [_]procmap.Input{
            .{ .start = 0x1000, .end = 0x4000, .offset = 0, .outcome = .{ .loaded = .{ .id = id, .delta = delta } } },
            .{ .start = 0x5000, .end = 0x6000, .offset = 0, .outcome = .{ .unavailable = .no_unwind_info } },
        };
        return .{ .set = set, .entry = try procmap.build(&inputs) };
    }

    fn deinit(self: *Fixture) void {
        self.set.deinit();
    }
};

fn putWord(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

fn stackAt(base: u64, mem: []const u8) frame.Stack {
    return .{ .base = base, .bytes = mem };
}

test "a frameless leaf, a function with a frame pointer and the outermost function" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x00, 0x2025); // the leaf's return address, on top of the stack
    putWord(&mem, 0x20, 0x7050); // B's saved rbp, at CFA-16
    putWord(&mem, 0x28, 0x3015); // B's return address, at CFA-8

    var out: [8]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x1010, .sp = 0x7000, .bp = 0x7020 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqualSlices(u64, &.{ 0x1010, 0x2025, 0x3015 }, out[0..r.count]);
    try testing.expectEqual(@as(usize, 0), r.fp_steps);
}

test "a mapping without a table is followed through the frame pointer chain" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x10, 0x7030); // the saved rbp, where rbp points
    putWord(&mem, 0x18, 0x2025); // the return address, above it
    putWord(&mem, 0x30, 0); // B's saved rbp, at its CFA-16
    putWord(&mem, 0x38, 0x3015); // B's return address

    var out: [8]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x5100, .sp = 0x7000, .bp = 0x7010 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqualSlices(u64, &.{ 0x5100, 0x2025, 0x3015 }, out[0..r.count]);
    try testing.expectEqual(@as(usize, 1), r.fp_steps);
}

test "an address no function covers: stop without a frame pointer, follow it with one" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x10, 0x7030);
    putWord(&mem, 0x18, 0x2025);
    putWord(&mem, 0x30, 0);
    putWord(&mem, 0x38, 0x3015);
    var out: [8]u64 = undefined;

    // 0x1100 is inside the mapping, between functions.
    var r = walk(&fx.entry, &fx.set, .{ .pc = 0x1100, .sp = 0x7000, .bp = 0 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.no_function, r.stop);
    try testing.expectEqualSlices(u64, &.{0x1100}, out[0..r.count]);

    r = walk(&fx.entry, &fx.set, .{ .pc = 0x1100, .sp = 0x7000, .bp = 0x7010 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqualSlices(u64, &.{ 0x1100, 0x2025, 0x3015 }, out[0..r.count]);
    try testing.expectEqual(@as(usize, 1), r.fp_steps);
}

test "a return address in no mapping is not a return address, and is left out" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x00, 0x9000); // the leaf's "return address" points nowhere

    var out: [8]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x1010, .sp = 0x7000, .bp = 0 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.invalid_address, r.stop);
    try testing.expectEqualSlices(u64, &.{0x1010}, out[0..r.count]);
}

test "the innermost address is kept even when it is in no mapping" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    var out: [8]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x9000, .sp = 0x7000, .bp = 0 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.no_module, r.stop);
    try testing.expectEqualSlices(u64, &.{0x9000}, out[0..r.count]);
}

test "a stack pointer that does not move up is stuck" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x200;
    putWord(&mem, 0xf8, 0x3015); // at 0x6ff8: the return address for a CFA of 0x7000

    var out: [8]u64 = undefined;
    // In B's body the CFA is rbp+16 = 0x7000, which is not above the stack pointer 0x7000.
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x2024, .sp = 0x7000, .bp = 0x6ff0 }, stackAt(0x6f00, &mem), &out, .{});
    try testing.expectEqual(Stop.stuck, r.stop);
    try testing.expectEqualSlices(u64, &.{0x2024}, out[0..r.count]);
}

test "a full output is truncated, not an error" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x00, 0x2025);
    putWord(&mem, 0x20, 0x7050);
    putWord(&mem, 0x28, 0x3015);

    var out: [2]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x1010, .sp = 0x7000, .bp = 0x7020 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.truncated, r.stop);
    try testing.expectEqual(@as(usize, 2), r.count);
}

test "a bad frame pointer is refused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    var out: [8]u64 = undefined;

    var r = walk(&fx.entry, &fx.set, .{ .pc = 0x5100, .sp = 0x7000, .bp = 0x7005 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.bad_frame_pointer, r.stop); // not aligned

    r = walk(&fx.entry, &fx.set, .{ .pc = 0x5100, .sp = 0x7000, .bp = 0x6000 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.bad_frame_pointer, r.stop); // below the stack pointer
}

test "a frame pointer that leads outside the readable stack stops the walk" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    var out: [8]u64 = undefined;
    const r = walk(&fx.entry, &fx.set, .{ .pc = 0x5100, .sp = 0x7000, .bp = 0x8000 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.outside_stack, r.stop);
    try testing.expectEqualSlices(u64, &.{0x5100}, out[0..r.count]);
}

test "a pc that is a return address is looked up one byte earlier" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x00, 0x3015);
    var out: [8]u64 = undefined;

    // 0x2000 is the first byte of B. As an instruction that was running it belongs to B.
    var r = walk(&fx.entry, &fx.set, .{ .pc = 0x2000, .sp = 0x7000, .bp = 0 }, stackAt(0x7000, &mem), &out, .{});
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqualSlices(u64, &.{ 0x2000, 0x3015 }, out[0..r.count]);

    // As a return address it is the end of whatever precedes B: no function covers 0x1fff.
    r = walk(&fx.entry, &fx.set, .{ .pc = 0x2000, .sp = 0x7000, .bp = 0 }, stackAt(0x7000, &mem), &out, .{ .innermost_is_return_address = true });
    try testing.expectEqual(Stop.no_function, r.stop);
    try testing.expectEqualSlices(u64, &.{0x2000}, out[0..r.count]);
}

const repair_call = [5]u8{ 0xe8, 0xeb, 0xf7, 0xff, 0xff }; // call 0x1800, ending at 0x2015

/// pc 0x1800 is in the mapping with tables but in no function. The word at sp is `word`; the
/// 5 bytes before 0x2015 are `call`. If the repair works, the caller is in B (frame pointer at
/// 0x8010, saved rbp 0, return address 0x3010 in C).
fn repairWalk(fx: *const Fixture, word: u64, call: [5]u8, bp: u64, with_code: bool, out: []u64) Result {
    var mem = [_]u8{0} ** 0x40;
    putWord(&mem, 0x00, word);
    putWord(&mem, 0x18, 0x3010);
    var code = [_]u8{0} ** 0x100;
    @memcpy(code[0x10..0x15], &call);
    const code_opt: ?Code = if (with_code) Code{ .base = 0x2000, .bytes = &code } else null;
    return walk(&fx.entry, &fx.set, .{ .pc = 0x1800, .sp = 0x8000, .bp = bp }, stackAt(0x8000, &mem), out, .{ .code = code_opt });
}

fn expectNoRepair(r: Result, out: []const u64) !void {
    try testing.expectEqual(Stop.no_function, r.stop);
    try testing.expectEqual(@as(usize, 1), r.count);
    try testing.expectEqual(@as(u64, 0x1800), out[0]);
}

test "leaf repair: the word at sp is the return address of a call into this function" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    const r = repairWalk(&fx, 0x2015, repair_call, 0x8010, true, &out);
    try testing.expectEqual(Stop.end, r.stop);
    try testing.expectEqualSlices(u64, &.{ 0x1800, 0x2015, 0x3010 }, out[0..r.count]);
    try testing.expectEqual(@as(usize, 0), r.fp_steps);
}

test "leaf repair: a word that points into no mapping is refused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    try expectNoRepair(repairWalk(&fx, 0x9000, repair_call, 0, true, &out), &out);
}

test "leaf repair: no call instruction before the word is refused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    const not_a_call = [5]u8{ 0x90, 0x90, 0x90, 0x90, 0x90 };
    try expectNoRepair(repairWalk(&fx, 0x2015, not_a_call, 0, true, &out), &out);
}

test "leaf repair: a call target outside every mapping is refused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    const to_0x800 = [5]u8{ 0xe8, 0xeb, 0xe7, 0xff, 0xff };
    try expectNoRepair(repairWalk(&fx, 0x2015, to_0x800, 0, true, &out), &out);
}

test "leaf repair: a call target after pc is refused" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    const to_0x1900 = [5]u8{ 0xe8, 0xeb, 0xf8, 0xff, 0xff };
    try expectNoRepair(repairWalk(&fx, 0x2015, to_0x1900, 0, true, &out), &out);
}

test "leaf repair: without code bytes nothing changes" {
    var fx = try Fixture.init(testing.allocator);
    defer fx.deinit();
    var out: [8]u64 = undefined;
    try expectNoRepair(repairWalk(&fx, 0x2015, repair_call, 0, false, &out), &out);
}

test "hashStack: the same stack gives the same hash, and any change gives another" {
    const a = [_]u64{ 0x1000, 0x2015, 0x3010 };
    const base = hashStack(&a, .end, false);
    try testing.expectEqual(base, hashStack(&a, .end, false));
    try testing.expect(base != hashStack(&[_]u64{ 0x2015, 0x1000, 0x3010 }, .end, false)); // order
    try testing.expect(base != hashStack(&[_]u64{ 0x1000, 0x2015 }, .end, false)); // length
    try testing.expect(base != hashStack(&a, .truncated, false)); // why it ended
    try testing.expect(base != hashStack(&a, .end, true)); // return address or not
}
