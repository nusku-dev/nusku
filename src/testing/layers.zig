//! The CLI's layers, bottom up: see shared/layers.zig for the rule.

const layers = @import("shared").layers;

test "every layer of the CLI imports only its own files and the facades below it" {
    const found = try layers.check(.{
        .base = "src",
        .root = "main.zig",
        .layers = &.{
            .{ .name = "term", .rank = 0 },
            // Beside each other: a view never asks the client, the client never prints.
            .{ .name = "client", .rank = 1 },
            .{ .name = "view", .rank = 1 },
            .{ .name = "cmd", .rank = 2 },
        },
    });
    try @import("std").testing.expectEqual(@as(u32, 0), found);
}
