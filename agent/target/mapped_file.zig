//! The file behind a region.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;
const build_id = @import("build_id.zig");
const process = @import("../os/os.zig").process;
const Region = @import("regions.zig").Region;

pub const Error = error{
    Unreadable,
    WrongFile,
};

pub fn open(pid: u32, region: *const Region, prefix_buffer: []u8) Error!File {
    assert(prefix_buffer.len >= build_id.prefix_size);

    var file = process.mapping_open(pid, region.path, region.start, region.end) catch
        return error.Unreadable;
    errdefer file.deinit();

    if (region.build_id) |expected| {
        const found = build_id.from_file(&file, prefix_buffer) orelse return error.WrongFile;
        if (!std.mem.eql(u8, found, expected)) return error.WrongFile;
    }
    return file;
}

const testing = std.testing;

fn region_test(path: []const u8, id: ?[]const u8) Region {
    return .{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = path,
        .build_id = id,
    };
}

test "a file that exists opens, a missing one is unreadable" {
    var prefix: [build_id.prefix_size]u8 = undefined;
    const pid = process.current_pid();

    var file = try open(pid, &region_test("/bin/sh", null), &prefix);
    file.deinit();
    const missing = region_test("/no/such/file", null);
    try testing.expectError(error.Unreadable, open(pid, &missing, &prefix));
}

test "a region with a build ID needs a file with the same one" {
    var prefix: [build_id.prefix_size]u8 = undefined;
    const pid = process.current_pid();

    var file = try open(pid, &region_test("/bin/sh", null), &prefix);
    const read = try file.read_at(&prefix, 0);
    file.deinit();
    const id = build_id.from_prefix(prefix[0..read]) orelse return error.SkipZigTest;

    var same = try open(pid, &region_test("/bin/sh", id), &prefix);
    same.deinit();

    var wrong: [build_id.id_bytes_max]u8 = undefined;
    @memcpy(wrong[0..id.len], id);
    wrong[0] ^= 0xff;
    const region_wrong = region_test("/bin/sh", wrong[0..id.len]);
    try testing.expectError(error.WrongFile, open(pid, &region_wrong, &prefix));
}
