//! Checks against real files that exist on the machine running the tests.
const std = @import("std");
const sections = @import("sections.zig");
const ehframe = @import("ehframe.zig");
const cfi = @import("cfi.zig");
const frame = @import("frame.zig");
const module = @import("module.zig");
const compact = @import("compact.zig");
const registry = @import("registry.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;

/// The whole file, or null if it cannot be opened.
fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const fd = open(path.ptr, 0 | 0o2000000); // read only, close on exec
    if (fd < 0) return null;
    defer _ = close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > 256 * 1024 * 1024) return error.TooLarge;
        try list.appendSlice(allocator, chunk[0..len]);
    }
    return try list.toOwnedSlice(allocator);
}

const real_files = [_][:0]const u8{
    "/usr/lib/x86_64-linux-gnu/libc.so.6",
    "/usr/bin/yes",
    "/usr/bin/ls",
};

test "real files: every entry of .eh_frame parses, and the counts can be compared with readelf" {
    var seen: usize = 0;
    for (real_files) |path| {
        const file = (try readFile(std.testing.allocator, path)) orelse continue;
        defer std.testing.allocator.free(file);
        const section = (try sections.find(file, ".eh_frame")) orelse continue;
        const bytes = sections.bytesOf(file, section) orelse return error.TestUnexpectedResult;

        var it = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        var count: usize = 0;
        var empty: usize = 0;
        var first: ?ehframe.Fde = null;
        var last: ?ehframe.Fde = null;
        while (try it.next()) |fde| {
            count += 1;
            if (fde.pc_end == fde.pc_begin) empty += 1;
            if (first == null) first = fde;
            last = fde;
        }

        std.debug.print("{s}: .eh_frame {d} bytes, {d} FDEs ({d} empty)\n", .{ path, bytes.len, count, empty });
        if (first) |f| std.debug.print("  first pc={x:0>16}..{x:0>16}\n", .{ f.pc_begin, f.pc_end });
        if (last) |l| std.debug.print("  last  pc={x:0>16}..{x:0>16}\n", .{ l.pc_begin, l.pc_end });

        try std.testing.expect(count > 0);
        if (std.mem.indexOf(u8, path, "libc.so") != null) try std.testing.expect(count > 1000);
        seen += 1;
    }
    if (seen == 0) return error.SkipZigTest;
}

test "real files: the rows of every function cover exactly its address range, with no gap" {
    var seen: usize = 0;
    for (real_files) |path| {
        const file = (try readFile(std.testing.allocator, path)) orelse continue;
        defer std.testing.allocator.free(file);
        const section = (try sections.find(file, ".eh_frame")) orelse continue;
        const bytes = sections.bytesOf(file, section) orelse return error.TestUnexpectedResult;

        var fdes = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        var functions: usize = 0;
        var row_count: usize = 0;
        var expressions: usize = 0;
        while (try fdes.next()) |fde| {
            functions += 1;
            var it = try cfi.rows(fde);
            var expected = fde.pc_begin;
            while (try it.next()) |entry| {
                try std.testing.expectEqual(expected, entry.start);
                expected = entry.end;
                row_count += 1;
                switch (entry.row.cfa) {
                    .expression => expressions += 1,
                    else => {},
                }
            }
            try std.testing.expectEqual(fde.pc_end, expected);
        }
        std.debug.print("{s}: {d} functions, {d} rows, {d} with a CFA expression\n", .{ path, functions, row_count, expressions });
        seen += 1;
    }
    if (seen == 0) return error.SkipZigTest;
}

test "real files: every row can be evaluated, and what the rows look like" {
    var seen: usize = 0;
    for (real_files) |path| {
        const file = (try readFile(std.testing.allocator, path)) orelse continue;
        defer std.testing.allocator.free(file);
        const section = (try sections.find(file, ".eh_frame")) orelse continue;
        const bytes = sections.bytesOf(file, section) orelse return error.TestUnexpectedResult;

        // Every register holds a different value, so a wrong register would show.
        var f = frame.Frame{ .regs = undefined };
        for (&f.regs, 0..) |*r, i| r.* = 0x100000 + 0x1000 * i;
        const no_memory = frame.Stack{ .base = 0, .bytes = &.{} };

        var by_reg = [_]usize{0} ** frame.num_regs;
        var rows: usize = 0;
        var expressions: usize = 0;
        var ra_below_cfa: usize = 0;
        var ra_undefined: usize = 0;
        var ra_other: usize = 0;

        var fdes = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        while (try fdes.next()) |fde| {
            var it = try cfi.rows(fde);
            while (try it.next()) |entry| {
                rows += 1;
                f.regs[cfi.reg_ra] = entry.start;

                switch (entry.row.cfa) {
                    .register => |c| by_reg[@intCast(c.reg)] += 1,
                    .expression => expressions += 1,
                    .unset => return error.TestUnexpectedResult,
                }
                _ = frame.cfaOf(entry.row, f, no_memory) catch |err| {
                    if (err == error.OutsideStack) {
                        // Some DWARF expressions dereference memory.
                        // This test has no real stack snapshot to read from.
                        continue;
                    }

                    std.debug.print("{s}: a row at {x} cannot be evaluated: {s}\n", .{
                        path,
                        entry.start,
                        @errorName(err),
                    });
                    return err;
                };

                switch (entry.row.rules[cfi.reg_ra]) {
                    .offset => |n| if (n == -8) {
                        ra_below_cfa += 1;
                    } else {
                        ra_other += 1;
                    },
                    .undef => ra_undefined += 1,
                    else => ra_other += 1,
                }
            }
        }

        std.debug.print("{s}: {d} rows. CFA from rsp {d}, rbp {d}, other register {d}, expression {d}\n", .{
            path, rows, by_reg[cfi.reg_rsp], by_reg[cfi.reg_rbp], rows - by_reg[cfi.reg_rsp] - by_reg[cfi.reg_rbp] - expressions, expressions,
        });
        std.debug.print("  return address at CFA-8 in {d} rows, undefined in {d}, anything else in {d}\n", .{ ra_below_cfa, ra_undefined, ra_other });
        seen += 1;
    }
    if (seen == 0) return error.SkipZigTest;
}

test "real files: a module finds every function by an address inside it, at the right bias" {
    const chosen_bias: u64 = 0x7f0000000000; // what address randomization would add
    var seen: usize = 0;
    for (real_files) |path| {
        const file = (try readFile(std.testing.allocator, path)) orelse continue;
        defer std.testing.allocator.free(file);
        const section = (try sections.find(file, ".eh_frame")) orelse continue;
        const bytes = sections.bytesOf(file, section) orelse return error.TestUnexpectedResult;

        // The mapping the kernel makes of the code, at a random address. It maps whole pages.
        const segment = (try sections.firstExecutable(file)) orelse continue;
        const page: u64 = 0xfff;
        const start = chosen_bias + (segment.vaddr & ~page);
        var m = try module.Module.load(std.testing.allocator, file, start, start + 1, segment.offset & ~page);
        defer m.deinit(std.testing.allocator);
        try std.testing.expectEqual(chosen_bias, m.bias);

        var fdes = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
        var checked: usize = 0;
        while (try fdes.next()) |fde| {
            if (fde.pc_end == fde.pc_begin) continue;
            const first = m.find(fde.pc_begin + chosen_bias) orelse return error.TestUnexpectedResult;
            const last = m.find(fde.pc_end - 1 + chosen_bias) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(fde.pc_begin, first.pc_begin);
            try std.testing.expectEqual(fde.pc_begin, last.pc_begin);
            checked += 1;
        }
        try std.testing.expectEqual(checked, m.fdes.len);

        // Just before the first function, and just after the last one.
        try std.testing.expect(m.find(m.fdes[0].pc_begin + chosen_bias - 1) == null);
        try std.testing.expect(m.find(m.fdes[m.fdes.len - 1].pc_end + chosen_bias) == null);

        std.debug.print("{s}: {d} functions found by address, bias 0x{x}\n", .{ path, checked, m.bias });
        seen += 1;
    }
    if (seen == 0) return error.SkipZigTest;
}

const Outside = struct { reg: usize, slot: u64 };

/// The full rules also read the places where registers other than rbp are saved. The compact
/// row does not track those, because nothing the walk needs depends on them. If one of those
/// places is outside the snapshot, the full rules fail where the compact row rightly does not.
fn untrackedSlotOutside(row: cfi.Row, f: frame.Frame, stack: frame.Stack) ?Outside {
    const cfa = frame.cfaOf(row, f, stack) catch return null;
    for (row.rules, 0..) |rule, i| {
        if (i == cfi.reg_rbp or i == cfi.reg_rsp or i == cfi.reg_ra) continue;
        switch (rule) {
            .offset => |n| {
                const slot = cfa +% @as(u64, @bitCast(n));
                if (stack.readU64(slot) == null) return .{ .reg = i, .slot = slot };
            },
            else => {},
        }
    }
    return null;
}

test "real files: the compact table gives the same caller as the full rules on every row" {
    const allocator = std.testing.allocator;
    var seen: usize = 0;
    for (real_files) |path| {
        const file = (try readFile(allocator, path)) orelse continue;
        defer allocator.free(file);
        const segment = (try sections.firstExecutable(file)) orelse continue;
        const page: u64 = 0xfff;
        const start = segment.vaddr & ~page;
        var m = module.Module.load(allocator, file, start, start + 1, segment.offset & ~page) catch continue;
        defer m.deinit(allocator);

        var table = try compact.build(allocator, m.fdes);
        defer table.deinit(allocator);

        // The same pseudo-random stack for every probe, so a wrong read would give a wrong value.
        const mem = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(mem);
        var x: u64 = 0x9e3779b97f4a7c15;
        var at: usize = 0;
        while (at + 8 <= mem.len) : (at += 8) {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            std.mem.writeInt(u64, mem[at..][0..8], x, .little);
        }
        const sp: u64 = 0x7ffd00000000;
        const stack = frame.Stack{ .base = sp, .bytes = mem };

        var same: usize = 0;
        var both_outside: usize = 0;
        var untracked_outside: usize = 0;
        var unsupported: usize = 0;
        var shown_unsupported: usize = 0;
        var shown_untracked: usize = 0;
        var shown_both: usize = 0;
        for (m.fdes) |fde| {
            var it = try cfi.rows(fde);
            while (try it.next()) |entry| {
                const probes = [_]u64{ entry.start, entry.start + (entry.end - entry.start) / 2, entry.end - 1 };
                for (probes) |a| {
                    const found = table.find(a) orelse {
                        std.debug.print("{s}: no compact row at 0x{x}\n", .{ path, a });
                        return error.TestUnexpectedResult;
                    };
                    if (found.cfa_type == @intFromEnum(compact.CfaType.unsupported)) {
                        unsupported += 1;
                        if (shown_unsupported < 10) {
                            shown_unsupported += 1;
                            std.debug.print("  unsupported at 0x{x}: CFA {s}, return address {s}\n", .{
                                a, @tagName(entry.row.cfa), @tagName(entry.row.rules[cfi.reg_ra]),
                            });
                        }
                        continue;
                    }

                    var f = frame.Frame{ .regs = [_]u64{0} ** frame.num_regs };
                    f.regs[cfi.reg_rsp] = sp;
                    f.regs[cfi.reg_rbp] = sp + 0x2000;
                    f.regs[cfi.reg_ra] = a;
                    const regs = compact.Regs{ .pc = a, .sp = sp, .bp = sp + 0x2000 };

                    const full = frame.unwindOne(entry.row, f, stack);
                    const small = compact.unwind(found, regs, stack);
                    if (full) |next| {
                        const got = small catch |err| {
                            std.debug.print("{s}: the compact row failed ({s}) where the full rules worked, at 0x{x}\n", .{ path, @errorName(err), a });
                            return error.TestUnexpectedResult;
                        };
                        switch (next) {
                            .outermost => switch (got) {
                                .end => {},
                                .caller => return error.TestUnexpectedResult,
                            },
                            .caller => |c| switch (got) {
                                .caller => |g| {
                                    try std.testing.expectEqual(c.regs[cfi.reg_ra], g.pc);
                                    try std.testing.expectEqual(c.regs[cfi.reg_rsp], g.sp);
                                    try std.testing.expectEqual(c.regs[cfi.reg_rbp], g.bp);
                                },
                                .end => return error.TestUnexpectedResult,
                            },
                        }
                        same += 1;
                    } else |err| {
                        if (err != error.OutsideStack) {
                            std.debug.print("{s}: the full rules failed with {s} at 0x{x}\n", .{ path, @errorName(err), a });
                            return error.TestUnexpectedResult;
                        }
                        if (small) |_| {
                            const outside = untrackedSlotOutside(entry.row, f, stack) orelse {
                                std.debug.print("{s}: only the full rules failed at 0x{x}, and no untracked register explains it. CFA {s}, compact type {d}, offset {d}\n", .{
                                    path, a, @tagName(entry.row.cfa), found.cfa_type, found.cfa_offset,
                                });
                                return error.TestUnexpectedResult;
                            };
                            untracked_outside += 1;
                            if (shown_untracked < 5) {
                                shown_untracked += 1;
                                std.debug.print("  at 0x{x}: {s} is saved {d} bytes from the stack pointer, outside the snapshot\n", .{
                                    a, cfi.regName(outside.reg), @as(i64, @bitCast(outside.slot -% sp)),
                                });
                            }
                        } else |small_err| {
                            try std.testing.expectEqual(error.OutsideStack, small_err);
                            both_outside += 1;
                            if (shown_both < 5) {
                                shown_both += 1;
                                const cfa = frame.cfaOf(entry.row, f, stack) catch 0;
                                std.debug.print("  both failed at 0x{x}: CFA {s} offset {d}, return address slot {d} bytes from the stack pointer\n", .{
                                    a, @tagName(entry.row.cfa), found.cfa_offset, @as(i64, @bitCast(cfa -% 8 -% sp)),
                                });
                            }
                        }
                    }
                }
            }
        }

        // Gaps between functions are found as gaps, and so are the addresses around the table.
        var prev_end: ?u64 = null;
        for (m.fdes) |fde| {
            if (prev_end) |pe| {
                if (fde.pc_begin > pe) {
                    try std.testing.expect(table.find(pe) == null);
                    try std.testing.expect(table.find(fde.pc_begin - 1) == null);
                }
            } else {
                try std.testing.expect(table.find(fde.pc_begin -% 1) == null);
            }
            prev_end = fde.pc_end;
        }
        try std.testing.expect(table.find(prev_end.?) == null);

        std.debug.print("{s}: {d} addresses give the same caller. Failed outside the snapshot in both: {d}. In the full rules only, because of an untracked register's slot: {d}. Unsupported probes: {d}\n", .{
            path, same, both_outside, untracked_outside, unsupported,
        });
        std.debug.print("  table: {d} rows, {d} bytes. rsp {d}, rbp {d}, plt {d}, end {d}, unsupported {d}\n", .{
            table.rows.len,
            table.rows.len * @sizeOf(compact.Row),
            table.count(.rsp),
            table.count(.rbp),
            table.count(.plt),
            table.count(.end),
            table.count(.unsupported),
        });
        seen += 1;
    }
    if (seen == 0) return error.SkipZigTest;
}

test "real files: each binary is loaded once, and another process's mapping gets the right bias" {
    const allocator = std.testing.allocator;
    var reg = registry.Registry.init(allocator, 300_000, 16);
    defer reg.deinit();

    var loaded: u32 = 0;
    for (real_files) |path| {
        const file = (try readFile(allocator, path)) orelse continue;
        defer allocator.free(file);
        const segment = (try sections.firstExecutable(file)) orelse continue;
        const page: u64 = 0xfff;
        const offset = segment.offset & ~page;
        const start_a = (segment.vaddr & ~page) + 0x7f00_0000_0000;
        const start_b = start_a + 0x1_2340_0000; // the same file in a process with another ASLR

        const identity = registry.Identity{ .file = .{ .inode = loaded + 1, .path = path } };
        const first = try reg.add(identity, file, start_a, start_a + 0x1000, offset);
        if (first == .unavailable) continue;

        const known = (try reg.lookup(identity)).?;
        try std.testing.expect(std.meta.eql(first, known));

        var direct = try module.Module.load(allocator, file, start_b, start_b + 0x1000, offset);
        defer direct.deinit(allocator);
        try std.testing.expectEqual(direct.bias, registry.biasOf(first.loaded.delta, start_b, offset));
        try std.testing.expect(reg.set.find(first.loaded.id, direct.fdes[0].pc_begin) != null);
        loaded += 1;
    }
    try std.testing.expect(loaded > 0);
    try std.testing.expectEqual(@as(usize, loaded), reg.set.modules.items.len);
    std.debug.print("registry: {d} binaries, {d} rows in total\n", .{ loaded, reg.set.rows.items.len });
}
