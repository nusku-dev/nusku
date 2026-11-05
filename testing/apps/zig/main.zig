//! A small Zig program whose CPU profile is known in advance, to check nusku against.
//!
//! Every round of 100 ms is split by the clock, not by how much work gets done, so the shares
//! are the same on any machine:
//!
//!   50%  run -> hot -> hot_leaf                          a plain loop in one function
//!   30%  run -> warm -> recurse x8                       a recursion 8 deep, spinning at the bottom
//!   20%  run -> cold -> std.mem.sort -> compare          the stack goes through std and back
//!
//! Built in release mode, without frame pointers: nusku unwinds it with .eh_frame. It runs for
//! a minute; nusku stops it sooner when it profiles it with --duration.

const std = @import("std");
const linux = std.os.linux;

const ns_per_ms = std.time.ns_per_ms;
const seconds = 60;

/// Keeps the work from being optimized away.
var sink: u64 = 0;

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

noinline fn hot_leaf(until_ns: u64) u64 {
    var x: u64 = 1;
    while (now_ns() < until_ns) {
        for (0..4096) |_| x = x *% 6364136223846793005 +% 1442695040888963407;
    }
    return x;
}

noinline fn hot(until_ns: u64) void {
    sink +%= hot_leaf(until_ns);
}

noinline fn recurse(depth: u32, until_ns: u64) u64 {
    if (depth > 1) return recurse(depth - 1, until_ns) +% 1;
    var x: u64 = 3;
    while (now_ns() < until_ns) {
        for (0..4096) |_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
        }
    }
    return x;
}

noinline fn warm(until_ns: u64) void {
    sink +%= recurse(8, until_ns);
}

var numbers: [2048]i32 = undefined;

noinline fn compare(_: void, a: i32, b: i32) bool {
    return a < b;
}

noinline fn cold(until_ns: u64) void {
    var seed: u32 = 7;
    while (now_ns() < until_ns) {
        for (&numbers) |*number| {
            seed = seed *% 1103515245 +% 12345;
            number.* = @bitCast(seed);
        }
        std.mem.sort(i32, &numbers, {}, compare);
    }
    sink +%= @as(u32, @bitCast(numbers[0]));
}

noinline fn run(until_ns: u64) void {
    while (now_ns() < until_ns) {
        const start = now_ns();
        hot(start + 50 * ns_per_ms);
        warm(start + 80 * ns_per_ms);
        cold(start + 100 * ns_per_ms);
    }
}

pub fn main() u8 {
    run(now_ns() + seconds * std.time.ns_per_s);
    return @intFromBool(sink == 42); // Almost surely 0; reading `sink` keeps the work.
}
