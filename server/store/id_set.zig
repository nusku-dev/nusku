//! A few build IDs, copied into fixed slots: no allocation, ever. The server keeps two: the
//! binaries a run is sending now (claimed, so no other run sends them too), and the binaries
//! whose table could not be built (refused, so no run sends them again).

const std = @import("std");
const assert = std.debug.assert;

/// A build ID is a few bytes to a few dozen; the upload refuses longer ones.
pub const id_bytes_max = 256;

pub fn IdSet(comptime slots_max: usize) type {
    return struct {
        const Set = @This();

        ids: [slots_max][id_bytes_max]u8 = undefined,
        /// 0 for a free slot.
        lengths: [slots_max]u16 = @splat(0),
        /// Where `add_over_oldest` writes next: the slots are reused in turn.
        next: usize = 0,

        pub const Slot = usize;

        pub fn has(set: *const Set, id: []const u8) bool {
            return set.find(id) != null;
        }

        /// Puts `id` in a free slot and returns it, or null when every slot is taken.
        pub fn add(set: *Set, id: []const u8) ?Slot {
            for (set.lengths, 0..) |length, slot| {
                if (length != 0) continue;
                set.write(slot, id);
                return slot;
            }
            return null;
        }

        /// Puts `id` in the set, over the slot written longest ago if there is no room: for a
        /// set that only has to remember the recent ones.
        pub fn add_over_oldest(set: *Set, id: []const u8) void {
            if (set.has(id)) return;
            set.write(set.next, id);
            set.next = (set.next + 1) % slots_max;
        }

        pub fn remove(set: *Set, slot: Slot) void {
            assert(set.lengths[slot] != 0);
            set.lengths[slot] = 0;
        }

        fn find(set: *const Set, id: []const u8) ?Slot {
            for (set.lengths, 0..) |length, slot| {
                if (length == id.len and std.mem.eql(u8, set.ids[slot][0..length], id)) {
                    return slot;
                }
            }
            return null;
        }

        fn write(set: *Set, slot: Slot, id: []const u8) void {
            assert(id.len > 0 and id.len <= id_bytes_max);
            @memcpy(set.ids[slot][0..id.len], id);
            set.lengths[slot] = @intCast(id.len);
        }
    };
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "slots are taken, given back and reused; a full set says so" {
    var set: IdSet(2) = .{};
    const a = set.add("aa").?;
    _ = set.add("bb").?;
    try testing.expect(set.has("aa") and set.has("bb") and !set.has("cc"));
    try testing.expectEqual(@as(?usize, null), set.add("cc"));

    set.remove(a);
    try testing.expect(!set.has("aa"));
    try testing.expect(set.add("cc") != null);
    try testing.expect(set.has("cc"));
}

test "add_over_oldest keeps the most recent ids" {
    var set: IdSet(2) = .{};
    set.add_over_oldest("aa");
    set.add_over_oldest("bb");
    set.add_over_oldest("bb"); // Already in: takes no slot.
    set.add_over_oldest("cc"); // Over "aa", the oldest.
    try testing.expect(!set.has("aa") and set.has("bb") and set.has("cc"));
}
