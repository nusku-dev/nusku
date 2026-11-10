//! The os layer: what the server's threads share.

const lock = @import("lock.zig");

pub const Lock = lock.Lock;
pub const Condition = lock.Condition;

test {
    _ = lock;
}
