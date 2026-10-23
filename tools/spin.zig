//! A program to profile, with known answers: `spin` does all the work, and `hotA` calls it
//! three times as much as `hotB`. Runs until it is killed.
const std = @import("std");

fn spin(n: u64) u64 {
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        x = x *% 6364136223846793005 +% i;
    }
    return x;
}

fn hotA() u64 {
    return @call(.never_inline, spin, .{30_000_000});
}

fn hotB() u64 {
    return @call(.never_inline, spin, .{10_000_000});
}

pub fn main() void {
    var sink: u64 = 0;
    while (true) {
        sink +%= @call(.never_inline, hotA, .{});
        sink +%= @call(.never_inline, hotB, .{});
        std.mem.doNotOptimizeAway(sink);
    }
}
