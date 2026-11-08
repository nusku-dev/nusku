//! The example of devlog Ep14, on the public API only: `profile` on its own thread, each report
//! copied into owned memory and handed over, a `Cancel` to stop it. Built by every test build,
//! so the guide cannot go stale.

const std = @import("std");
const agent = @import("../../root.zig");
const Message = @import("../../message.zig").Message;

/// Copies every report into a Message and passes it to `send`, the server's side.
pub const Forwarder = struct {
    /// Holds the current message. Reset at every report, so memory stays bounded.
    arena: std.heap.ArenaAllocator,
    messages_sent: u32 = 0,
    /// Called on the profiling thread: a real server pushes the message onto a queue here, and
    /// must copy it if it keeps it past the call.
    send: *const fn (context: *anyopaque, message: *const Message) anyerror!void,
    send_context: *anyopaque,

    /// The callback `profile` calls once per interval. An error stops the run.
    pub fn on_report(forwarder: *Forwarder, report: *const agent.Report) !void {
        _ = forwarder.arena.reset(.retain_capacity);
        const message = try Message.from_report(forwarder.arena.allocator(), report);
        try forwarder.send(forwarder.send_context, &message);
        forwarder.messages_sent += 1;
    }
};

/// One profiling run on a thread of its own: `profile` blocks its thread until the run stops.
pub const Run = struct {
    thread: std.Thread,
    /// Written by the thread before it ends: read it after `join`.
    result: anyerror!agent.StopReason = error.NotFinished,

    pub fn start(
        run: *Run,
        gpa: std.mem.Allocator,
        options: agent.Options,
        forwarder: *Forwarder,
    ) !void {
        run.* = .{ .thread = undefined };
        run.thread = try std.Thread.spawn(.{}, run_thread, .{ run, gpa, options, forwarder });
    }

    fn run_thread(
        run: *Run,
        gpa: std.mem.Allocator,
        options: agent.Options,
        forwarder: *Forwarder,
    ) void {
        run.result = agent.profile(gpa, options, forwarder, Forwarder.on_report);
    }

    pub fn join(run: *Run) anyerror!agent.StopReason {
        run.thread.join();
        return run.result;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("../process.zig");
const timer = @import("../../os/timer.zig");

/// The test's "server": it only counts what it receives. `send` runs on the profiling thread
/// and the test reads the counts on its own, so they are atomic.
const Received = struct {
    messages: std.atomic.Value(u32) = .init(0),
    samples: std.atomic.Value(u64) = .init(0),
    regions_max: std.atomic.Value(u64) = .init(0),

    fn send(context: *anyopaque, message: *const Message) anyerror!void {
        const received: *Received = @ptrCast(@alignCast(context));
        _ = received.samples.fetchAdd(message.samples, .monotonic);
        _ = received.regions_max.fetchMax(message.regions.len, .monotonic);
        _ = received.messages.fetchAdd(1, .release);
    }
};

test "the Ep14 example: a run on its own thread, fed to a server, stopped by a cancel (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    const child = try child_process.burner_spawn(5000);
    defer child_process.child_reap(child);

    var received = Received{};
    var forwarder = Forwarder{
        .arena = .init(testing.allocator),
        .send = Received.send,
        .send_context = &received,
    };
    defer forwarder.arena.deinit();

    var cancel = try agent.Cancel.init();
    defer cancel.deinit();

    var run: Run = undefined;
    try run.start(testing.allocator, .{
        .pid = child,
        .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
        .interval_ms = 100,
        .duration_s = 0,
        .cancel = &cancel,
    }, &forwarder);

    // Starting takes a while (loading the program, building the tables of the test binary):
    // count from the first message, so the test does not depend on how long.
    var waited_ms: u32 = 0;
    while (received.messages.load(.acquire) == 0) : (waited_ms += 10) {
        if (waited_ms >= 10_000) return error.NoMessage;
        timer.sleep_ms(10);
    }
    timer.sleep_ms(350);
    cancel.trigger(); // From this thread: the run stops at its next wait.
    const reason = try run.join();

    const messages = received.messages.load(.acquire);
    const samples = received.samples.load(.monotonic);
    std.debug.print("example: {d} messages, {d} samples\n", .{ messages, samples });
    try testing.expectEqual(agent.StopReason.cancelled, reason);
    try testing.expect(messages >= 4); // The first, then about every 100 ms, then the last.
    try testing.expect(samples >= 20); // About 45 for 450 ms at 99 Hz.
    try testing.expect(received.regions_max.load(.monotonic) > 0);
}
