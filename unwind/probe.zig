//! Freezes a thread of a running process, copies its registers and the top of its stack, and
//! unwinds it with the .eh_frame of the modules the process has loaded. It is for trying the
//! unwinder on real processes. It needs root, and it stops the thread for about a millisecond
//! per sample, so it is not for production.
//!
//! Usage: unwind-probe PID [TID [COUNT]]
//! With a COUNT above 1 it samples that many times and prints how often each call chain was seen.
const std = @import("std");
const unwind = @import("root.zig");
const symbolizer = @import("symbolizer");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn pread(fd: c_int, buf: *anyopaque, count: usize, offset: i64) isize;
extern "c" fn ptrace(request: c_int, ...) c_long;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Off when UNWIND_NO_LEAF_REPAIR is set, to compare the two.
var leaf_repair = true;
const PTRACE_GETREGS = 12;
const PTRACE_DETACH = 17;
const PTRACE_SEIZE = 0x4206;
const PTRACE_INTERRUPT = 0x4207;
const WAIT_ALL = 0x40000000; // __WALL: wait for threads too

/// struct user_regs_struct of x86-64, in the order the kernel writes it.
const UserRegs = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rax: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    orig_rax: u64,
    rip: u64,
    cs: u64,
    eflags: u64,
    rsp: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,
};

/// The registers in DWARF numbering, which is what the unwinder works with.
fn frameOf(r: UserRegs) unwind.frame.Frame {
    return .{ .regs = .{
        r.rax, r.rdx, r.rcx, r.rbx, r.rsi, r.rdi, r.rbp, r.rsp,
        r.r8,  r.r9,  r.r10, r.r11, r.r12, r.r13, r.r14, r.r15,
        r.rip,
    } };
}

const Mapping = struct {
    start: u64,
    end: u64,
    offset: u64,
    path: []const u8,
};

fn readFile(arena: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = open(path.ptr, 0 | 0o2000000); // read only, close on exec
    if (fd < 0) return error.CannotOpen;
    defer _ = close(fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) return error.CannotRead;
        if (n == 0) break;
        try list.appendSlice(arena, chunk[0..@intCast(n)]);
    }
    return list.toOwnedSlice(arena);
}

/// The executable mappings that belong to a file, from the text of /proc/PID/maps.
fn parseMaps(arena: std.mem.Allocator, text: []const u8) !std.ArrayList(Mapping) {
    var list: std.ArrayList(Mapping) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const range = it.next() orelse continue;
        const perms = it.next() orelse continue;
        const offset = it.next() orelse continue;
        _ = it.next() orelse continue; // the device
        _ = it.next() orelse continue; // the inode
        const path = std.mem.trim(u8, it.rest(), " ");
        if (perms.len < 4 or perms[2] != 'x' or path.len == 0 or path[0] != '/') continue;

        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue;
        const off = std.fmt.parseInt(u64, offset, 16) catch continue;
        try list.append(arena, .{ .start = start, .end = end, .offset = off, .path = path });
    }
    return list;
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// Turns addresses into text: a function name if the file has symbols, else file and offset.
const Symbols = struct {
    arena: std.mem.Allocator,
    pid: c_int,
    mappings: []const Mapping,
    binaries: std.StringHashMapUnmanaged(?symbolizer.binary.Binary) = .empty,

    fn binaryFor(self: *Symbols, path: []const u8) !?symbolizer.binary.Binary {
        const slot = try self.binaries.getOrPut(self.arena, path);
        if (!slot.found_existing) {
            var buf: [4200]u8 = undefined;
            const opened: ?symbolizer.binary.Binary = blk: {
                const z = std.fmt.bufPrintZ(&buf, "/proc/{d}/root{s}", .{ self.pid, path }) catch break :blk null;
                break :blk symbolizer.binary.Binary.open(self.arena, z) catch null;
            };
            slot.value_ptr.* = opened;
        }
        return slot.value_ptr.*;
    }

    /// A return address points just after a call, so the function is looked up one byte earlier.
    fn label(self: *Symbols, addr: u64, is_return: bool) ![]const u8 {
        const probe = if (is_return) addr -% 1 else addr;
        var found: ?Mapping = null;
        for (self.mappings) |m| {
            if (probe >= m.start and probe < m.end) {
                found = m;
                break;
            }
        }
        const m = found orelse return std.fmt.allocPrint(self.arena, "?0x{x}", .{addr});

        const file_offset = probe - m.start + m.offset;
        if (try self.binaryFor(m.path)) |bin| {
            if (bin.resolve(file_offset)) |match| {
                return std.fmt.allocPrint(self.arena, "{s}+0x{x}", .{ match.name, match.offset });
            }
        }
        return std.fmt.allocPrint(self.arena, "?{s}+0x{x}", .{ baseName(m.path), file_offset });
    }
};

fn freeze(tid: c_int) !UserRegs {
    if (ptrace(PTRACE_SEIZE, tid, @as(usize, 0), @as(usize, 0)) != 0) return error.CannotAttach;
    errdefer detach(tid);
    if (ptrace(PTRACE_INTERRUPT, tid, @as(usize, 0), @as(usize, 0)) != 0) return error.CannotInterrupt;

    var status: c_int = 0;
    if (waitpid(tid, &status, WAIT_ALL) != tid) return error.WaitFailed;
    if (status & 0xff != 0x7f) return error.NotStopped; // not in the stopped state

    var regs: UserRegs = undefined;
    if (ptrace(PTRACE_GETREGS, tid, @as(usize, 0), @intFromPtr(&regs)) != 0) return error.CannotReadRegisters;
    return regs;
}

fn detach(tid: c_int) void {
    _ = ptrace(PTRACE_DETACH, tid, @as(usize, 0), @as(usize, 0));
}

const Sample = struct {
    regs: UserRegs,
    in_syscall: bool,
    addrs: []const u64,
    stop: unwind.walk.Stop,
    fp_steps: usize,
    repairs: usize,
};

fn takeSample(
    arena: std.mem.Allocator,
    tid: c_int,
    memfd: c_int,
    modules: []const unwind.module.Module,
    stack_buf: []u8,
) !Sample {
    const regs = try freeze(tid);
    const sp = std.math.cast(i64, regs.rsp) orelse {
        detach(tid);
        return error.BadStackPointer;
    };
    const n = pread(memfd, stack_buf.ptr, stack_buf.len, sp);
    detach(tid); // the thread runs again; everything below works on the copy
    if (n <= 0) return error.CannotReadStack;

    // orig_rax is -1 unless the thread is inside a system call. Then the pc is the address
    // after the syscall instruction, a return address.
    const in_syscall = regs.orig_rax != std.math.maxInt(u64);
    var out: [256]u64 = undefined;
    const result = unwind.walk.walk(
        modules,
        frameOf(regs),
        .{ .base = regs.rsp, .bytes = stack_buf[0..@intCast(n)] },
        &out,
        .{ .innermost_is_return_address = in_syscall, .leaf_repair = leaf_repair },
    );
    return .{ .regs = regs, .in_syscall = in_syscall, .addrs = try arena.dupe(u64, out[0..result.count]), .stop = result.stop, .fp_steps = result.fp_steps, .repairs = result.repairs };
}

/// The call chain as text, innermost first.
fn chainText(arena: std.mem.Allocator, symbols: *Symbols, s: Sample) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (s.addrs, 0..) |addr, i| {
        if (i > 0) try text.appendSlice(arena, " < ");
        try text.appendSlice(arena, try symbols.label(addr, i > 0 or s.in_syscall));
    }
    if (s.stop != .end) {
        try text.appendSlice(arena, try std.fmt.allocPrint(arena, "  [stopped: {s}]", .{@tagName(s.stop)}));
    }
    if (s.fp_steps > 0) {
        try text.appendSlice(arena, try std.fmt.allocPrint(arena, "  [frame pointer steps: {d}]", .{s.fp_steps}));
    }
    if (s.repairs > 0) {
        try text.appendSlice(arena, try std.fmt.allocPrint(arena, "  [leaf repairs: {d}]", .{s.repairs}));
    }
    return text.toOwnedSlice(arena);
}

const Entry = struct { text: []const u8, n: usize };

fn moreOften(_: void, a: Entry, b: Entry) bool {
    return a.n > b.n;
}

fn run(arena: std.mem.Allocator, args: anytype) !void {
    const pid = try std.fmt.parseInt(c_int, args[1], 10);
    const tid = if (args.len > 2) try std.fmt.parseInt(c_int, args[2], 10) else pid;
    const repeat = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else 1;

    var path_buf: [64]u8 = undefined;
    const maps_text = try readFile(arena, try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/maps", .{pid}));
    const mappings = try parseMaps(arena, maps_text);

    // Every executable mapping becomes a module. Those whose file has unwind information get
    // it; the others are known to be code and can only be followed through frame pointers.
    var modules: std.ArrayList(unwind.module.Module) = .empty;
    var with_tables: usize = 0;
    for (mappings.items) |m| {
        var buf: [4200]u8 = undefined;
        const bytes: ?[]u8 = blk: {
            const proc_path = std.fmt.bufPrintZ(&buf, "/proc/{d}/root{s}", .{ pid, m.path }) catch break :blk null;
            break :blk readFile(arena, proc_path) catch |err| {
                std.debug.print("  cannot read {s}: {s}\n", .{ m.path, @errorName(err) });
                break :blk null;
            };
        };
        const file = bytes orelse {
            try modules.append(arena, unwind.module.Module.withoutUnwindInfo(m.start, m.end));
            continue;
        };
        if (unwind.module.Module.load(arena, file, m.start, m.end, m.offset)) |mod| {
            with_tables += 1;
            try modules.append(arena, mod);
        } else |err| {
            std.debug.print("  no unwind information in {s} ({s})\n", .{ m.path, @errorName(err) });
            try modules.append(arena, unwind.module.Module.codeOnly(m.start, m.end, file, m.offset));
        }
    }
    std.debug.print("{d} executable mappings, {d} with unwind information\n", .{ mappings.items.len, with_tables });
    const memfd = open((try std.fmt.bufPrintZ(&path_buf, "/proc/{d}/mem", .{pid})).ptr, 0 | 0o2000000);
    if (memfd < 0) return error.CannotOpenMemory;
    defer _ = close(memfd);

    var symbols = Symbols{ .arena = arena, .pid = pid, .mappings = mappings.items };
    const stack_buf = try arena.alloc(u8, 128 * 1024);

    if (repeat == 1) {
        const s = try takeSample(arena, tid, memfd, modules.items, stack_buf);
        std.debug.print("thread {d}: rip=0x{x} rsp=0x{x} rbp=0x{x}{s}\n", .{
            tid, s.regs.rip, s.regs.rsp, s.regs.rbp, if (s.in_syscall) " (in a system call)" else "",
        });

        for (s.addrs, 0..) |addr, i| {
            std.debug.print("  #{d:<2} 0x{x:0>16}  {s}\n", .{ i, addr, try symbols.label(addr, i > 0 or s.in_syscall) });
        }
        std.debug.print("walk stopped: {s} after {d} frames, {d} of the steps through frame pointers\n", .{ @tagName(s.stop), s.addrs.len, s.fp_steps });
        return;
    }

    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    var i: u32 = 0;
    while (i < repeat) : (i += 1) {
        const s = try takeSample(arena, tid, memfd, modules.items, stack_buf);
        const slot = try counts.getOrPut(arena, try chainText(arena, &symbols, s));
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
        _ = usleep(10_000);
    }

    var entries: std.ArrayList(Entry) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| try entries.append(arena, .{ .text = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, moreOften);
    for (entries.items) |e| {
        std.debug.print("{d:>5}  {d:>5.1}%  {s}\n", .{ e.n, 100.0 * @as(f64, @floatFromInt(e.n)) / @as(f64, @floatFromInt(repeat)), e.text });
    }
}

pub fn main(init: std.process.Init) u8 {
    if (getenv("UNWIND_NO_LEAF_REPAIR") != null) leaf_repair = false;
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return 1;
    if (args.len < 2 or args.len > 4) {
        std.debug.print("usage: unwind-probe PID [TID [COUNT]]\n", .{});
        return 2;
    }
    run(arena, args) catch |err| {
        std.debug.print("unwind-probe: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
