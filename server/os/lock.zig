//! A mutex for the few places where threads meet: the server's store, and a condition to wait
//! on under it. Thin wrappers over the libc ones, which need no setup and no `io`. Keep what
//! runs under the lock short and bounded.

const std = @import("std");
const assert = std.debug.assert;

pub const Lock = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    // The receiver is not called `lock`: that is the name of the method.
    pub fn lock(mutex: *Lock) void {
        const result = std.c.pthread_mutex_lock(&mutex.inner);
        assert(result == .SUCCESS);
    }

    pub fn unlock(mutex: *Lock) void {
        const result = std.c.pthread_mutex_unlock(&mutex.inner);
        assert(result == .SUCCESS);
    }
};

/// Waits for something that another thread changes under a `Lock`. As with every condition, a
/// wake-up may be spurious: wait in a loop that checks what is waited for.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    /// Lets go of `held` while waiting, and holds it again when it returns.
    pub fn wait(condition: *Condition, held: *Lock) void {
        const result = std.c.pthread_cond_wait(&condition.inner, &held.inner);
        assert(result == .SUCCESS);
    }

    /// Wakes every waiter.
    pub fn broadcast(condition: *Condition) void {
        const result = std.c.pthread_cond_broadcast(&condition.inner);
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
