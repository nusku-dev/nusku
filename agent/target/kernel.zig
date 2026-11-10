//! The identity of the running kernel.

const std = @import("std");
const File = @import("shared").File;

const assert = std.debug.assert;

const build_id = @import("build_id.zig");
const log = @import("../log.zig").agent;

pub const Identity = struct {
    release: []const u8 = "",
    build_id: ?[]const u8 = null,
    text_address: ?u64 = null,
};

pub fn read(arena: std.mem.Allocator) !Identity {
    var identity = Identity{};

    if (try file_read_or_null(arena, "/proc/sys/kernel/osrelease", 256)) |text| {
        identity.release = trailing_space_trim(text);
    }

    if (try file_read_or_null(arena, "/sys/kernel/notes", 64 * 1024)) |notes| {
        identity.build_id = build_id.find_build_id(notes);
    }

    if (File.open("/proc/kallsyms")) |opened| {
        var file = opened;
        defer file.deinit();
        identity.text_address = text_address_scan(16 * 1024, &file);
    } else |_| {}

    log.debug("kernel identity", .{
        .release = identity.release,
        .build_id_found = identity.build_id != null,
        .text_address_found = identity.text_address != null,
    });
    return identity;
}

fn text_address_scan(comptime chunk: usize, source: *const File) ?u64 {
    var buffer: [chunk]u8 = undefined;
    var kept: usize = 0;
    var offset: u64 = 0;
    var stext: ?u64 = null;
    const limit = 4 * 1024 * 1024;

    while (offset < limit) {
        const n = source.read_at(buffer[kept..], offset) catch break;
        if (n == 0) break;
        offset += n;
        const filled = kept + n;

        const lines_end = (std.mem.lastIndexOfScalar(u8, buffer[0..filled], '\n') orelse break) + 1;
        if (address_of(buffer[0..lines_end], "_text")) |address| return address;
        if (stext == null) stext = address_of(buffer[0..lines_end], "_stext");

        kept = filled - lines_end;
        std.mem.copyForwards(u8, buffer[0..kept], buffer[lines_end..filled]);
    }
    return stext;
}

fn address_of(kallsyms: []const u8, symbol: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, kallsyms, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const address_text = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, symbol)) continue;
        const address = std.fmt.parseInt(u64, address_text, 16) catch continue;
        if (address != 0) return address;
    }
    return null;
}

fn file_read_or_null(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) !?[]u8 {
    return file_read(gpa, path, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn file_read(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ![]u8 {
    var file = try File.open(path);
    defer file.deinit();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&chunk);
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > max_bytes) return error.TooLarge;
        try list.appendSlice(gpa, chunk[0..len]);
    }
    return list.toOwnedSlice(gpa);
}

fn trailing_space_trim(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    return text[0..end];
}
