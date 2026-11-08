//! The agent's layers, bottom up: see shared/layers.zig for the rule.

const layers = @import("shared").layers;

test "every layer of the agent imports only its own files and the facades below it" {
    const found = try layers.check(.{
        .base = "agent",
        .layers = &.{
            .{ .name = "os", .rank = 0 },
            .{ .name = "elf", .rank = 1 },
            .{ .name = "target", .rank = 2 },
            .{ .name = "unwind", .rank = 3 },
            // Beside each other: none may use another.
            .{ .name = "ebpf", .rank = 4 },
            .{ .name = "symbols", .rank = 4 },
            .{ .name = "processes", .rank = 4 },
        },
    });
    try @import("std").testing.expectEqual(@as(u32, 0), found);
}
