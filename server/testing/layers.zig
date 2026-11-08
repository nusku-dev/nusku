//! The server's layers, bottom up: see shared/layers.zig for the rule.

const layers = @import("shared").layers;

test "every layer of the server imports only its own files and the facades below it" {
    const found = try layers.check(.{
        .base = "server",
        .layers = &.{
            .{ .name = "os", .rank = 0 },
            // Beside each other: none may use another.
            .{ .name = "windows", .rank = 1 },
            .{ .name = "symbols", .rank = 1 },
            .{ .name = "processes", .rank = 1 },
            .{ .name = "naming", .rank = 2 },
            .{ .name = "server", .rank = 3 },
            .{ .name = "control", .rank = 4 },
        },
    });
    try @import("std").testing.expectEqual(@as(u32, 0), found);
}
