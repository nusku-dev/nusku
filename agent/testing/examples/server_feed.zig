//! The example of devlog Ep14: how a server feeds itself from the agent's public API.
//!
//! The pattern: run `profile` on a thread of its own; in the report callback, copy what the
//! server needs into owned memory (the report is only valid during the callback), and hand the
//! copy over; stop the run from any thread with a `Cancel`.
//!
//! It only uses the public API (root.zig), as a server would. Test-only: the test at the end
//! runs it for real (as root), and every test build compiles it, so the guide cannot go stale.

const std = @import("std");
const agent = @import("../../root.zig");

/// What the server receives for one report: owned, plain data, ready to be serialized (into a
/// protobuf message, later) or kept.
pub const Message = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    pid: u32,
    /// Samples per second per CPU: `samples / sample_hz` is CPU seconds.
    sample_hz: u32,
    samples: u64,
    /// Samples the window misses, all reasons together (see agent.cpu.Loss for each).
    samples_lost: u64,
    regions: []const agent.Region,
    stacks: []const Stack,

    pub const Stack = struct {
        samples: u64,
        user: []const u64,
        kernel: []const u64,
        /// The walk reached the outermost frame: nothing is cut.
        complete: bool,
    };
};

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
        const message = try message_copy(forwarder.arena.allocator(), report);
        try forwarder.send(forwarder.send_context, &message);
        forwarder.messages_sent += 1;
    }
};

/// The report, deep-copied into `arena`. Everything in a report points into the agent's own
/// buffers, which the next report reuses.
pub fn message_copy(arena: std.mem.Allocator, report: *const agent.Report) !Message {
    const regions = try arena.alloc(agent.Region, report.regions.len);
    for (regions, report.regions) |*copy, region| {
        copy.* = region;
        copy.path = try arena.dupe(u8, region.path);
        copy.build_id = if (region.build_id) |id| try arena.dupe(u8, id) else null;
    }

    var message = Message{
        .start_unix_ns = report.start_unix_ns,
        .duration_ns = report.duration_ns,
        .pid = report.pid,
        .sample_hz = 0,
        .samples = 0,
        .samples_lost = 0,
        .regions = regions,
        .stacks = &.{},
    };
    // The cpu field is null when the cpu metric was not asked for.
    const window = report.cpu orelse return message;
    const loss = window.loss;
    message.sample_hz = window.sample_hz;
    message.samples = window.samples;
    message.samples_lost = loss.ring_full + loss.counts_full + loss.frames_missing;

    const stacks = try arena.alloc(Message.Stack, window.stacks.len);
    for (stacks, window.stacks) |*copy, stack| {
        copy.* = .{
            .samples = stack.samples,
            .user = try arena.dupe(u64, stack.user),
            .kernel = try arena.dupe(u64, stack.kernel),
            .complete = stack.stop == .end,
        };
    }
    message.stacks = stacks;
    return message;
}

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
