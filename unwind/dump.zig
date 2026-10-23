//! Prints the unwind rows of every function in a binary's .eh_frame, one line per row, in a
//! form that tools/cfi-compare.py can compare with what readelf says.
const std = @import("std");
const sections = @import("sections.zig");
const ehframe = @import("ehframe.zig");
const cfi = @import("cfi.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;

fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = open(path.ptr, 0 | 0o2000000); // read only, close on exec
    if (fd < 0) return error.CannotOpen;
    defer _ = close(fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &chunk, chunk.len);
        if (n < 0) return error.CannotRead;
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > 512 * 1024 * 1024) return error.TooLarge;
        try list.appendSlice(allocator, chunk[0..len]);
    }
    return list.toOwnedSlice(allocator);
}

fn dump(arena: std.mem.Allocator, path: []const u8, w: *std.Io.Writer) !void {
    const file = try readFile(arena, try arena.dupeZ(u8, path));
    const section = (try sections.find(file, ".eh_frame")) orelse return error.NoEhFrame;
    const bytes = sections.bytesOf(file, section) orelse return error.BadSection;

    var fdes = (ehframe.EhFrame{ .bytes = bytes, .vaddr = section.vaddr }).iterator();
    var count: usize = 0;
    var failed: usize = 0;
    while (try fdes.next()) |fde| {
        count += 1;
        try w.print("FDE {x:0>16}..{x:0>16}\n", .{ fde.pc_begin, fde.pc_end });

        var it = cfi.rows(fde) catch |err| {
            try w.print("ERROR {s}\n", .{@errorName(err)});
            failed += 1;
            continue;
        };
        while (true) {
            const next = it.next() catch |err| {
                try w.print("ERROR {s}\n", .{@errorName(err)});
                failed += 1;
                break;
            };
            const e = next orelse break;
            try w.print("ROW {x:0>16} ", .{e.start});
            try cfi.writeCfa(w, e.row.cfa);
            for (e.row.rules) |rule| {
                try w.writeAll(" ");
                try cfi.writeRule(w, rule);
            }
            try w.writeAll("\n");
        }
    }
    try w.print("DONE {d} {d}\n", .{ count, failed });
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return 1;
    if (args.len != 2) {
        std.debug.print("usage: unwind-dump FILE\n", .{});
        return 2;
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var status: u8 = 0;
    dump(arena, args[1], &out.interface) catch |err| {
        std.debug.print("unwind-dump: {s}\n", .{@errorName(err)});
        status = 1;
    };
    out.interface.flush() catch return 1;
    return status;
}
