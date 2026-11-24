//! What the function probe and the agent exchange.

/// Calls nested deeper than this in one thread are counted, not timed.
pub const depth_max: u32 = 16;

/// Threads that can be inside the function at once.
pub const threads_max: u32 = 16384;

/// One bucket per power of two of nanoseconds: bucket b holds calls of [2^(b-1), 2^b) ns.
pub const buckets: u32 = 64;

pub const Config = extern struct {
    tgid: u32,
    pad: u32 = 0,
};

/// The calls a thread is inside, outermost first.
pub const Calls = extern struct {
    depth: u32,
    pad: u32 = 0,
    started_ns: [depth_max]u64,
};

/// Per CPU, counted since the probe was attached.
pub const Stats = extern struct {
    /// Entries seen.
    calls: u64,
    /// Returns timed: their durations are in `total_ns`, `max_ns` and `buckets`.
    timed: u64,
    total_ns: u64,
    max_ns: u64,
    /// Returns of calls nested deeper than `depth_max`.
    untimed: u64,
    /// Returns with no entry seen: calls already running when the probe was attached.
    unmatched: u64,
    /// Entries that found no room to keep their start: more threads inside than `threads_max`.
    dropped: u64,
    pad: u64 = 0,
    histogram: [buckets]u64,
};

comptime {
    if (depth_max & (depth_max - 1) != 0) @compileError("depth_max must be a power of two");
    if (@sizeOf(Calls) != 8 + 8 * depth_max) @compileError("Calls must have no padding");
    if (@sizeOf(Stats) != 8 * (8 + buckets)) @compileError("Stats must have no padding");
}

/// The bucket of a duration: the number of bits it needs.
pub inline fn bucket_of(ns: u64) u32 {
    var value = ns;
    var bits: u32 = 0;
    inline for (.{ 32, 16, 8, 4, 2, 1 }) |shift| {
        if (value >> shift != 0) {
            value >>= shift;
            bits += shift;
        }
    }
    if (ns == 0) return 0;
    return @min(bits + 1, buckets - 1);
}

test "a duration's bucket is the number of bits it needs" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0), bucket_of(0));
    try testing.expectEqual(@as(u32, 1), bucket_of(1));
    try testing.expectEqual(@as(u32, 2), bucket_of(2));
    try testing.expectEqual(@as(u32, 2), bucket_of(3));
    try testing.expectEqual(@as(u32, 11), bucket_of(1024));
    try testing.expectEqual(@as(u32, buckets - 1), bucket_of(@as(u64, 1) << 63));
}
