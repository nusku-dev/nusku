const std = @import("std");
const session = @import("session.zig");

pub const Config = @import("config.zig").Config;

test "test the tests in root " {
    try std.testing.expectEqual(1, 1);
}

test {
    _ = session;
}
