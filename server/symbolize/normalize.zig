//! Places the user addresses of a stack in files: the region, and the offset in its file. That
//! place is the same in every process and run, whatever ASLR did.

const std = @import("std");
const agent = @import("agent");
const regions_file = @import("regions.zig");

const assert = std.debug.assert;
const Region = agent.Region;

/// Marks a location in no region (anonymous memory, a gap, address 0).
pub const region_none: u32 = std.math.maxInt(u32);

pub const Location = struct {
    /// Index into the message's regions, or `region_none`.
    region: u32,
    /// In the region's file, of the instruction to name. The raw address for `region_none`.
    offset: u64,

    pub fn mapped(location: Location) bool {
        return location.region != region_none;
    }
};

/// The locations of `user`, into `out`. A return address points after its call, maybe into
/// the next function, so it is looked up one byte back: every frame but the first, and the
/// first too when `leaf_is_return` (a sample in a system call).
pub fn user_locate(
    regions: []const Region,
    user: []const u64,
    leaf_is_return: bool,
    out: []Location,
) void {
    assert(out.len == user.len);
    assert(regions.len < region_none);

    for (user, out, 0..) |address, *location, index| {
        const is_return = index > 0 or leaf_is_return;
        location.* = address_locate(regions, address, is_return);
    }
}

fn address_locate(regions: []const Region, address: u64, is_return: bool) Location {
    // There is no address before 0.
    if (is_return and address == 0) return .{ .region = region_none, .offset = address };

    const lookup = if (is_return) address - 1 else address;
    const index = regions_file.find(regions, lookup) orelse
        return .{ .region = region_none, .offset = address };
    return .{
        .region = @intCast(index),
        .offset = regions_file.file_offset(&regions[index], lookup),
    };
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn region_test(start: u64, end: u64, offset: u64) Region {
    return .{
        .start = start,
        .end = end,
        .offset = offset,
        .inode = 1,
        .path = "",
        .build_id = null,
    };
}

const regions_test = [_]Region{
    region_test(0x1000, 0x2000, 0),
    region_test(0x3000, 0x4000, 0x1000),
};

test "the running instruction is exact, return addresses are looked up one byte back" {
    const user = [_]u64{ 0x1500, 0x3500, 0x2000, 0x9000, 0x0 };
    var out: [5]Location = undefined;
    user_locate(&regions_test, &user, false, &out);

    // The running instruction: exact.
    try testing.expectEqual(@as(u32, 0), out[0].region);
    try testing.expectEqual(@as(u64, 0x500), out[0].offset);
    // A return address: the call is at 0x34ff, in the second region (offset 0x1000 in its file).
    try testing.expectEqual(@as(u32, 1), out[1].region);
    try testing.expectEqual(@as(u64, 0x14ff), out[1].offset);
    // A return address at the very end of the first region: the call was in that region, not
    // in whatever starts at 0x2000.
    try testing.expectEqual(@as(u32, 0), out[2].region);
    try testing.expectEqual(@as(u64, 0xfff), out[2].offset);
    // In no region: the raw address is kept.
    try testing.expect(!out[3].mapped());
    try testing.expectEqual(@as(u64, 0x9000), out[3].offset);
    // Address 0 as a return address.
    try testing.expect(!out[4].mapped());
    try testing.expectEqual(@as(u64, 0), out[4].offset);
}

test "a leaf that is a return address is looked up one byte back too" {
    var out: [1]Location = undefined;

    user_locate(&regions_test, &.{0x1500}, true, &out);
    try testing.expectEqual(@as(u32, 0), out[0].region);
    try testing.expectEqual(@as(u64, 0x4ff), out[0].offset);

    // Exactly at the start of a region, one byte back is the gap before it.
    user_locate(&regions_test, &.{0x3000}, true, &out);
    try testing.expect(!out[0].mapped());
    try testing.expectEqual(@as(u64, 0x3000), out[0].offset);

    // The same address as the running instruction is inside the region.
    user_locate(&regions_test, &.{0x3000}, false, &out);
    try testing.expectEqual(@as(u32, 1), out[0].region);
    try testing.expectEqual(@as(u64, 0x1000), out[0].offset);
}

test "no regions and no frames" {
    var out: [2]Location = undefined;
    user_locate(&.{}, &.{ 0x1500, 0x1600 }, false, &out);
    try testing.expect(!out[0].mapped());
    try testing.expect(!out[1].mapped());

    var none: [0]Location = undefined;
    user_locate(&regions_test, &.{}, false, &none);
}
