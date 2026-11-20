//! The target's executable regions.

const std = @import("std");
const process_maps = @import("process_maps.zig");
const build_id = @import("build_id.zig");
const vdso = @import("vdso.zig");

const Mapping = process_maps.Mapping;

const assert = std.debug.assert;

pub const Region = @import("shared").protocol.Region;

pub fn build(
    arena: std.mem.Allocator,
    mappings: []const Mapping,
    pid: u32,
    previous: []const Region,
) ![]Region {
    const regions = try arena.alloc(Region, mappings.len);
    for (mappings, regions, 0..) |mapping, *region, index| {
        assert(mapping.start < mapping.end);
        region.* = .{
            .start = mapping.start,
            .end = mapping.end,
            .offset = mapping.offset,
            .inode = mapping.inode,
            .path = mapping.path,
            .build_id = try build_id_for(arena, pid, mapping, .{
                .built = regions[0..index],
                .previous = previous,
            }),
        };
    }
    return regions;
}

/// The image must outlive the regions.
pub fn vdso_mark(regions: []Region, image: ?*const vdso.Image) void {
    const found = image orelse return;
    const id = found.build_id orelse return;
    for (regions) |*region| {
        if (!std.mem.eql(u8, region.path, vdso.path)) continue;
        if (found.matches(region.end - region.start)) region.build_id = id;
    }
}

fn build_id_for(
    arena: std.mem.Allocator,
    pid: u32,
    mapping: Mapping,
    known: struct { built: []const Region, previous: []const Region },
) !?[]const u8 {
    if (region_find(known.built, mapping)) |same| {
        return same.build_id;
    }
    if (region_find(known.previous, mapping)) |same| {
        const found = same.build_id orelse return null;
        return try arena.dupe(u8, found);
    }
    return build_id.for_mapping(arena, pid, mapping);
}

fn region_find(regions: []const Region, mapping: Mapping) ?*const Region {
    for (regions) |*region| {
        if (region.inode == mapping.inode) {
            if (std.mem.eql(u8, region.path, mapping.path)) return region;
        }
    }
    return null;
}

const read = process_maps.read;
const process = @import("../os/os.zig").process;

const Location = struct {
    region: *const Region,
    file_offset: u64,
};

fn locate(regions: []const Region, address: u64) ?Location {
    for (regions) |*r| {
        if (address >= r.start and address < r.end) {
            return .{ .region = r, .file_offset = address - r.start + r.offset };
        }
    }
    return null;
}

fn marker() void {}

test "this process: a raw address from our own code resolves to a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();

    const map = try read(arena.allocator(), pid);

    const regions = try build(arena.allocator(), map, pid, &.{});
    const hit = locate(regions, @intFromPtr(&marker)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit.region.path.len > 0);
    try std.testing.expect(hit.region.path[0] == '/');
}

test "locate finds the region and the offset inside its file" {
    const regions = [_]Region{
        .{
            .start = 0x1000,
            .end = 0x3000,
            .offset = 0x500,
            .inode = 1,
            .path = "/bin/a",
            .build_id = null,
        },
        .{
            .start = 0x7000,
            .end = 0x8000,
            .offset = 0,
            .inode = 2,
            .path = "[vdso]",
            .build_id = null,
        },
    };
    const hit = locate(&regions, 0x1234) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/bin/a", hit.region.path);
    try std.testing.expectEqual(@as(u64, 0x1234 - 0x1000 + 0x500), hit.file_offset);

    try std.testing.expect(locate(&regions, 0x3000) == null);
    try std.testing.expect(locate(&regions, 0xfff) == null);
    const vdso_test = locate(&regions, 0x7fff) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("[vdso]", vdso_test.region.path);
}

test "vdso_mark gives the [vdso] region the build ID of the agent's own image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    const id = image.build_id orelse return error.SkipZigTest;

    const file = Region{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = "/bin/a",
        .build_id = null,
    };
    var same = file;
    same.start = 0x7000;
    same.end = 0x7000 + image.bytes.len;
    same.path = vdso.path;
    var other = same;
    other.end += 4096;
    var regions = [_]Region{ file, same, other };
    vdso_mark(&regions, &image);

    try std.testing.expect(regions[0].build_id == null);
    try std.testing.expectEqualSlices(u8, id, regions[1].build_id.?);
    try std.testing.expect(regions[2].build_id == null);
}

test "this process: the [vdso] region of the real maps gets an ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();

    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    if (image.build_id == null) return error.SkipZigTest;
    const regions = try build(arena.allocator(), try read(arena.allocator(), pid), pid, &.{});
    vdso_mark(regions, &image);

    for (regions) |region| {
        if (std.mem.eql(u8, region.path, vdso.path)) {
            try std.testing.expect(region.build_id != null);
            return;
        }
    }
    return error.SkipZigTest;
}

test "a binary deleted while it runs keeps its build ID, and still opens (root)" {
    const child_process = @import("../testing/process.zig");
    const mapped_file = @import("mapped_file.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var path_buffer: [64]u8 = undefined;
    const own = process.current_pid();
    const copy = try std.fmt.bufPrintZ(&path_buffer, "/tmp/nusku-deleted-test-{d}", .{own});
    const argv = [_:null]?[*:0]const u8{ "sleep", "30" };
    const pid = try child_process.copy_spawn("/bin/sleep", copy, &argv);
    defer child_process.child_reap(pid);

    const before = try region_of(a, pid, copy, false);
    const id = before.build_id orelse return error.SkipZigTest;
    _ = std.c.unlink(copy.ptr);

    const after = try region_of(a, pid, copy, true);
    const id_after = after.build_id orelse {
        if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
        return error.NoBuildId;
    };
    try std.testing.expectEqualSlices(u8, id, id_after);
    var prefix: [build_id.prefix_size]u8 = undefined;
    var file = try mapped_file.open(pid, &after, &prefix);
    file.deinit();
}

fn region_of(arena: std.mem.Allocator, pid: u32, path: []const u8, deleted: bool) !Region {
    const mappings = try read(arena, pid);
    for (mappings) |mapping| {
        if (!std.mem.eql(u8, mapping.path, path)) continue;
        try std.testing.expectEqual(deleted, mapping.deleted);
        const regions = try build(arena, &.{mapping}, pid, &.{});
        return regions[0];
    }
    return error.NotMapped;
}
