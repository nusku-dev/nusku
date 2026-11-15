//! The os layer: what the server's threads share.

const lock = @import("lock.zig");
const lib_debug_info_d = @import("lib_debug_info_d.zig");

pub const Lock = lock.Lock;
pub const Condition = lock.Condition;
pub const Library = lib_debug_info_d.Library;

test {
    _ = lock;
    _ = lib_debug_info_d;
}
