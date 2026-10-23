//! Checks against files that exist on the machine running the tests. A test whose file is
//! missing is skipped, not failed.
const std = @import("std");
const elf = @import("elf.zig");
const index = @import("index.zig");
const files = @import("files.zig");
const binary = @import("binary.zig");
const store = @import("store.zig");
const kernel = @import("kernel.zig");

const libc_paths = [_][:0]const u8{
    "/usr/lib/x86_64-linux-gnu/libc.so.6",
    "/lib/x86_64-linux-gnu/libc.so.6",
    "/usr/lib64/libc.so.6",
    "/lib64/libc.so.6",
};

fn loadLibc(allocator: std.mem.Allocator) !?[]u8 {
    for (libc_paths) |path| {
        if (files.readAll(allocator, path, 64 * 1024 * 1024)) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        }
    }
    return null;
}

test "a real libc: dynamic symbols are read and every one is found at its own address" {
    const allocator = std.testing.allocator;
    const bytes = (try loadLibc(allocator)) orelse return error.SkipZigTest;
    defer allocator.free(bytes);

    const file = try elf.Elf.parse(bytes);
    try std.testing.expect(file.vaddrOf(0) != null); // the first loadable segment starts at the file's start

    // Count the function symbols and remember where "write" is.
    var write_value: ?u64 = null;
    var write_size: u64 = 0;
    var count: usize = 0;
    var it = try file.symbols(.dynsym);
    while (it.next()) |symbol| {
        count += 1;
        if (std.mem.eql(u8, symbol.name, "write")) {
            write_value = symbol.value;
            write_size = symbol.size;
        }
    }
    try std.testing.expect(count > 500);
    const write_at = write_value orelse return error.TestUnexpectedResult;
    try std.testing.expect(write_size > 4);

    var idx = try index.Index.build(allocator, file);
    defer idx.deinit(allocator);
    try std.testing.expect(idx.entries.len > 300);
    try std.testing.expect(idx.entries.len <= count); // aliases collapse, they never multiply

    std.debug.print("libc: {d} function symbols, {d} distinct addresses, write at 0x{x} (size {d})\n", .{
        count, idx.entries.len, write_at, write_size,
    });

    // "write" has aliases such as "__write"; the one with the fewest underscores must win.
    const at_start = idx.lookup(write_at) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("write", at_start.name);
    try std.testing.expectEqual(@as(u64, 0), at_start.offset);

    const inside = idx.lookup(write_at + 4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("write", inside.name);
    try std.testing.expectEqual(@as(u64, 4), inside.offset);

    // Every function symbol must be found at its own address, with offset 0.
    var all = try file.symbols(.dynsym);
    while (all.next()) |symbol| {
        const match = idx.lookup(symbol.value) orelse {
            std.debug.print("not found: {s} at 0x{x}\n", .{ symbol.name, symbol.value });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(u64, 0), match.offset);
    }
}

test "a real libc: the build ID is read" {
    const allocator = std.testing.allocator;
    const bytes = (try loadLibc(allocator)) orelse return error.SkipZigTest;
    defer allocator.free(bytes);

    const file = try elf.Elf.parse(bytes);
    const id = file.buildId() orelse return error.TestUnexpectedResult;
    std.debug.print("libc build id {x}\n", .{id});
    try std.testing.expect(id.len >= 16 and id.len <= 64);
}

fn openLibc(allocator: std.mem.Allocator) !?binary.Binary {
    for (libc_paths) |path| {
        if (binary.Binary.open(allocator, path)) |bin| {
            return bin;
        } else |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        }
    }
    return null;
}

test "a real libc: every function symbol's address converts to a file offset and back" {
    const allocator = std.testing.allocator;
    const bytes = (try loadLibc(allocator)) orelse return error.SkipZigTest;
    defer allocator.free(bytes);
    const file = try elf.Elf.parse(bytes);

    var checked: usize = 0;
    var it = try file.symbols(.dynsym);
    while (it.next()) |symbol| {
        const offset = file.fileOffsetOf(symbol.value) orelse {
            std.debug.print("no file offset: {s} at 0x{x}\n", .{ symbol.name, symbol.value });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(?u64, symbol.value), file.vaddrOf(offset));
        checked += 1;
    }
    try std.testing.expect(checked > 500);
}

test "a real libc: a file offset resolves to the function name, and the build ID matches" {
    const allocator = std.testing.allocator;
    var bin = (try openLibc(allocator)) orelse return error.SkipZigTest;
    defer bin.deinit(allocator);

    var write_value: ?u64 = null;
    var it = try bin.elf.symbols(.dynsym);
    while (it.next()) |symbol| {
        if (std.mem.eql(u8, symbol.name, "write")) write_value = symbol.value;
    }
    const vaddr = write_value orelse return error.TestUnexpectedResult;
    const offset = bin.elf.fileOffsetOf(vaddr) orelse return error.TestUnexpectedResult;
    std.debug.print("libc write: virtual address 0x{x}, file offset 0x{x}\n", .{ vaddr, offset });

    const at_start = bin.resolve(offset) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("write", at_start.name);
    try std.testing.expectEqual(@as(u64, 0), at_start.offset);

    const inside = bin.resolve(offset + 4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("write", inside.name);
    try std.testing.expectEqual(@as(u64, 4), inside.offset);

    const id = bin.buildId() orelse return error.TestUnexpectedResult;
    try std.testing.expect(bin.matches(id));
    var other: [64]u8 = undefined;
    @memcpy(other[0..id.len], id);
    other[0] ^= 0xff; // a different file
    try std.testing.expect(!bin.matches(other[0..id.len]));
}

test "a real libc is opened through /proc/<pid>/root and its build ID is checked" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(std.c.getpid());

    for (libc_paths) |path| {
        var reference = binary.Binary.open(allocator, path) catch |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        };
        defer reference.deinit(allocator);
        const id = reference.buildId() orelse return error.TestUnexpectedResult;

        var opened = try store.openLocal(allocator, me, path, .{ .build_id = id });
        opened.deinit(allocator);

        var wrong: [64]u8 = undefined;
        @memcpy(wrong[0..id.len], id);
        wrong[0] ^= 0xff;
        try std.testing.expectError(error.BuildIdMismatch, store.openLocal(allocator, me, path, .{ .build_id = wrong[0..id.len] }));
        return;
    }
    return error.SkipZigTest;
}

test "the running kernel: symbols are read and ksys_write is found (needs root, skipped otherwise)" {
    const allocator = std.testing.allocator;
    var k = kernel.Kernel.open(allocator) catch |err| switch (err) {
        error.NoSymbols, error.NoTextSymbol, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer k.deinit(allocator);

    var write_at: ?u64 = null;
    for (k.index.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "ksys_write")) write_at = entry.value;
    }
    const value = write_at orelse return error.TestUnexpectedResult;
    std.debug.print("kernel: _text at 0x{x}, {d} distinct addresses, ksys_write at 0x{x}\n", .{
        k.text_address, k.index.entries.len, value,
    });
    try std.testing.expect(k.index.entries.len > 10_000);

    const at_start = k.lookup(value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ksys_write", at_start.name);
    try std.testing.expectEqual(@as(u64, 0), at_start.offset);

    const inside = k.lookup(value + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ksys_write", inside.name);
    try std.testing.expectEqual(@as(u64, 1), inside.offset);
}

test "a real libc is also accepted by its inode, and another inode is refused" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(std.c.getpid());

    for (libc_paths) |path| {
        const read = files.readAllInode(allocator, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.NotFound => continue,
            else => return err,
        };
        defer allocator.free(read.bytes);
        std.debug.print("libc inode {d}\n", .{read.inode});

        var opened = try store.openLocal(allocator, me, path, .{ .inode = read.inode });
        opened.deinit(allocator);
        try std.testing.expectError(
            error.InodeMismatch,
            store.openLocal(allocator, me, path, .{ .inode = read.inode + 1 }),
        );
        return;
    }
    return error.SkipZigTest;
}
