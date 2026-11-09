//! The public API as a server uses it: a `Run` pulled on a thread of its own, each report
//! handed over, stopped from another thread. Built by every test build, so it cannot go stale.

const std = @import("std");
const agent = @import("../../root.zig");
const protocol = @import("shared").protocol;

/// Pulls the run's events until it stops, handing each report to `send`. Binaries are not
/// wanted here: a server that names addresses wants the ones it does not have.
fn run_thread(run: *agent.Run, received: *Received) void {
    while (run.next() catch null) |event| switch (event) {
        .report => |message| received.send(message),
        .binary_offer => run.binary_want(false),
        .stopped => |reason| received.stopped = reason,
        else => {},
    };
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("../process.zig");
const timer = @import("../../os/os.zig").timer;

/// The test's "server": it only counts. `send` runs on the run's thread and the test reads the
/// counts on its own, so they are atomic.
const Received = struct {
    messages: std.atomic.Value(u32) = .init(0),
    samples: std.atomic.Value(u64) = .init(0),
    regions_max: std.atomic.Value(u64) = .init(0),
    /// Read after the join.
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
    run.stop(); // From this thread: the run stops at its next wait.
    thread.join();

    const messages = received.messages.load(.acquire);
    const samples = received.samples.load(.monotonic);
    std.debug.print("example: {d} messages, {d} samples\n", .{ messages, samples });
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), received.stopped);
    try testing.expect(messages >= 4); // The first, then about every 100 ms, then the last.
    try testing.expect(samples >= 20); // About 45 for 450 ms at 99 Hz.
    try testing.expect(received.regions_max.load(.monotonic) > 0);
}
