const std = @import("std");
const process_maps = @import("process_maps.zig");
const buildId = @import("build_id.zig");

const Mapping = process_maps.Mapping;

const assert = std.debug.assert;

/// One executable region of the target process.
pub const Region = struct {
    start: u64,
    end: u64,
    /// The offset inside the file that `start` corresponds to.
    offset: u64,
    inode: u64,
    /// As the process sees it. Special regions have names like "[vdso]"; anonymous memory
    /// (for example JIT code) has an empty path.
    path: []const u8,
    /// Null when there is nothing to read (see buildid.forMapping).
    build_id: ?[]const u8,
};

pub fn regions_build(arena: std.mem.Allocator, maps: []Mapping, pid: u32, previous: []const Region) ![]const Region {
    const regions = try arena.alloc(Region, maps.len);
    for (maps, regions, 0..) |map, *region, idx| {
        assert(map.start < map.end);
        region.* = .{
            .start = map.start,
            .end = map.end,
            .offset = map.offset,
            .inode = map.inode,
            .path = map.path,
            .build_id = try build_id_for(arena, pid, map, .{
                .built = regions[0..idx],
                .previous = previous,
            }),
        };
    }

    return regions;
}

/// Reuses the build ID of a region for the same file, first from this table, then from
/// the previous one. Reads the file system only when neither has it.
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
        // The caller frees the previous table after this read, so copy.
        const build_id = same.build_id orelse return null;
        return try arena.dupe(u8, build_id);
    }
    return buildId.for_mapping(arena, pid, mapping);
}

fn region_find(regions: []const Region, mapping: Mapping) ?*const Region {
    for (regions) |*region| {
        if (region.inode == mapping.inode) {
            if (std.mem.eql(u8, region.path, mapping.path)) return region;
        }
    }
    return null;
}

// testing

const read = process_maps.read;
const sys = @import("../clibs/sys.zig");

const Location = struct {
    region: *const Region,
    /// Where the address is inside the region's file.
    file_offset: u64,
};

/// Which region a raw address falls into, and where in that region's file it is.
fn locate(regions: []const Region, address: u64) ?Location {
    for (regions) |*r| {
        if (address >= r.start and address < r.end) {
            return .{ .region = r, .file_offset = address - r.start + r.offset };
        }
    }
    return null;
}

fn testMarker() void {} // a function whose address lies inside this very binary

test "this process: a raw address from our own code resolves to a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pid = sys.currentPid();

    const map = try read(arena.allocator(), pid);

    const regions = try regions_build(arena.allocator(), map, pid, &.{});
    const hit = locate(regions, @intFromPtr(&testMarker)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(hit.region.path.len > 0);
    try std.testing.expect(hit.region.path[0] == '/');
}

test "locate finds the region and the offset inside its file" {
    const regions = [_]Region{
        .{ .start = 0x1000, .end = 0x3000, .offset = 0x500, .inode = 1, .path = "/bin/a", .build_id = null },
        .{ .start = 0x7000, .end = 0x8000, .offset = 0, .inode = 2, .path = "[vdso]", .build_id = null },
    };
    const hit = locate(&regions, 0x1234) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/bin/a", hit.region.path);
    try std.testing.expectEqual(@as(u64, 0x1234 - 0x1000 + 0x500), hit.file_offset);

    try std.testing.expect(locate(&regions, 0x3000) == null); // the end is exclusive
    try std.testing.expect(locate(&regions, 0xfff) == null);
    const vdso = locate(&regions, 0x7fff) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("[vdso]", vdso.region.path);
}
