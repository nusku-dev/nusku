//! A mutex for the few places where threads meet: the server's store. A thin wrapper over
//! the libc one, which needs no setup and no `io`. Keep what runs under it short and bounded.

const std = @import("std");

const assert = std.debug.assert;

pub const Lock = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Lock) void {
        const result = std.c.pthread_mutex_lock(&self.mutex);
        assert(result == .SUCCESS);
    }

    pub fn unlock(self: *Lock) void {
        const result = std.c.pthread_mutex_unlock(&self.mutex);
        assert(result == .SUCCESS);
    }
};

// ------------------------------------------------------------------------------------- tests

const Counter = struct {
    lock: Lock = .{},
    value: u64 = 0,

    fn run(counter: *Counter) void {
        for (0..100_000) |_| {
            counter.lock.lock();
            defer counter.lock.unlock();
            counter.value += 1;
        }
    }
};

test "two threads counting under the lock lose no increment" {
    var counter = Counter{};
    const first = try std.Thread.spawn(.{}, Counter.run, .{&counter});
    const second = try std.Thread.spawn(.{}, Counter.run, .{&counter});
    first.join();
    second.join();
    try std.testing.expectEqual(@as(u64, 200_000), counter.value);
}
