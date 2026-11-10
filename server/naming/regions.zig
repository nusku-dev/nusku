//! Which region an address is in.

const std = @import("std");
const protocol = @import("shared").protocol;

const assert = std.debug.assert;
const Region = protocol.Region;

pub fn valid(regions: []const Region) bool {
    for (regions, 0..) |region, index| {
        if (region.start >= region.end) return false;
        if (index > 0 and regions[index - 1].end > region.start) return false;
    }
    return true;
}

pub fn find(regions: []const Region, address: u64) ?usize {
    var low: usize = 0;
    var high: usize = regions.len;

    while (low < high) {
        const middle = low + (high - low) / 2;
        const region = &regions[middle];
        if (address < region.start) {
            high = middle;
        } else if (address >= region.end) {
            low = middle + 1;
        } else {
            return middle;
        }
    }
    return null;
}

pub fn file_offset(region: *const Region, address: u64) u64 {
    assert(address >= region.start and address < region.end);
    return address - region.start + region.offset;
}

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

test "find: inside, at the edges, in the gaps, before and after" {
    const regions = [_]Region{
        region_test(0x1000, 0x2000, 0),
        region_test(0x3000, 0x4000, 0x1000),
        region_test(0x7000, 0x8000, 0),
    };
    try testing.expect(valid(&regions));

    const none: ?usize = null;
    try testing.expectEqual(@as(?usize, 0), find(&regions, 0x1000));
    try testing.expectEqual(@as(?usize, 0), find(&regions, 0x1fff));
    try testing.expectEqual(none, find(&regions, 0x2000));
    try testing.expectEqual(@as(?usize, 1), find(&regions, 0x3500));
    try testing.expectEqual(none, find(&regions, 0x5000));
    try testing.expectEqual(@as(?usize, 2), find(&regions, 0x7fff));
    try testing.expectEqual(none, find(&regions, 0x0fff));
    try testing.expectEqual(none, find(&regions, 0x8000));
    try testing.expectEqual(none, find(&.{}, 0x1000));
}

test "file_offset adds the region's offset in the file" {
    const region = region_test(0x3000, 0x4000, 0x1000);
    try testing.expectEqual(@as(u64, 0x1000), file_offset(&region, 0x3000));
    try testing.expectEqual(@as(u64, 0x1abc), file_offset(&region, 0x3abc));
}

test "valid rejects empty, unsorted and overlapping regions" {
    try testing.expect(valid(&.{}));
    try testing.expect(!valid(&[_]Region{region_test(0x2000, 0x2000, 0)}));
    const unsorted = [_]Region{ region_test(0x3000, 0x4000, 0), region_test(0x1000, 0x2000, 0) };
    try testing.expect(!valid(&unsorted));
    const overlapping = [_]Region{ region_test(0x1000, 0x3000, 0), region_test(0x2000, 0x4000, 0) };
    try testing.expect(!valid(&overlapping));
}
