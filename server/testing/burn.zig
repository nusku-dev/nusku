//! Test-only: keeps the CPU busy.

const std = @import("std");

const turns_per_check = 1 << 20;

pub noinline fn burn(ms: u64) void {
    const start_ns = now_ns();
    var x: u64 = 0;
    while (now_ns() - start_ns < ms * std.time.ns_per_ms) {
        for (0..turns_per_check) |turn| x +%= turn;
    }
    std.mem.doNotOptimizeAway(x);
}

fn now_ns() u64 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}
