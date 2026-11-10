//! A mutex and a condition, over libc's: no setup and no `io` needed.

const std = @import("std");
const assert = std.debug.assert;

pub const Lock = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(mutex: *Lock) void {
        const result = std.c.pthread_mutex_lock(&mutex.inner);
        assert(result == .SUCCESS);
    }

    pub fn unlock(mutex: *Lock) void {
        const result = std.c.pthread_mutex_unlock(&mutex.inner);
        assert(result == .SUCCESS);
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(condition: *Condition, held: *Lock) void {
        const result = std.c.pthread_cond_wait(&condition.inner, &held.inner);
        assert(result == .SUCCESS);
    }

    pub fn broadcast(condition: *Condition) void {
        const result = std.c.pthread_cond_broadcast(&condition.inner);
        assert(result == .SUCCESS);
    }
};

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

const Flag = struct {
    lock: Lock = .{},
    changed: Condition = .{},
    set: bool = false,

    fn raise(flag: *Flag) void {
        flag.lock.lock();
        defer flag.lock.unlock();
        flag.set = true;
        flag.changed.broadcast();
    }
};

test "a wait under the lock sees what another thread set" {
    var flag = Flag{};
    flag.lock.lock();
    const thread = try std.Thread.spawn(.{}, Flag.raise, .{&flag});
    while (!flag.set) flag.changed.wait(&flag.lock);
    flag.lock.unlock();
    thread.join();
    try std.testing.expect(flag.set);
}
