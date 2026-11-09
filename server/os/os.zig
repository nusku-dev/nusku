//! The os layer: what the server's threads share. A toolbox: a lock, and a condition to wait
//! on under it. Imports nothing of the server.

const lock = @import("lock.zig");

pub const Lock = lock.Lock;
pub const Condition = lock.Condition;

test {
    _ = lock;
}
