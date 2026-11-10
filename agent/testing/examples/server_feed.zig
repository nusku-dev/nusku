//! The public API as a server uses it.

const std = @import("std");
const agent = @import("../../root.zig");
const protocol = @import("shared").protocol;

fn run_thread(run: *agent.Run, received: *Received) void {
    while (run.next() catch null) |event| switch (event) {
        .report => |message| received.send(message),
        .binary_offer => run.binary_want(false),
        .stopped => |reason| received.stopped = reason,
        else => {},
    };
}

const testing = std.testing;
const child_process = @import("../process.zig");
const timer = @import("../../os/os.zig").timer;

const Received = struct {
    messages: std.atomic.Value(u32) = .init(0),
    samples: std.atomic.Value(u64) = .init(0),
    regions_max: std.atomic.Value(u64) = .init(0),
    stopped: ?protocol.RunStop = null,

    fn send(received: *Received, message: *const protocol.Message) void {
        _ = received.samples.fetchAdd(message.samples, .monotonic);
        _ = received.regions_max.fetchMax(message.regions.len, .monotonic);
        _ = received.messages.fetchAdd(1, .release);
    }
};

test "a run on its own thread, fed to a server, stopped from another thread (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    var run = try agent.Run.init(testing.allocator, .{ .pid = child, .interval_ms = 100 });
    defer run.deinit();
    var received = Received{};
    const thread = try std.Thread.spawn(.{}, run_thread, .{ &run, &received });

    var waited_ms: u32 = 0;
    while (received.messages.load(.acquire) == 0) : (waited_ms += 10) {
        if (waited_ms >= 10_000) return error.NoMessage;
        timer.sleep_ms(10);
    }
    timer.sleep_ms(350);
    run.stop();
    thread.join();

    const messages = received.messages.load(.acquire);
    const samples = received.samples.load(.monotonic);
    std.debug.print("example: {d} messages, {d} samples\n", .{ messages, samples });
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), received.stopped);
    try testing.expect(messages >= 4);
    try testing.expect(samples >= 20);
    try testing.expect(received.regions_max.load(.monotonic) > 0);
}
