//! End to end: from a running process to a profile with names in it.
//!
//! How: the controller profiles this test process for real (BPF program, perf events, unwind
//! tables) while it spins in `burn`. On the way, the agent offers the binaries it sees, and the
//! server builds their symbol tables on a thread of its own. Then the profile must name `burn`,
//! and name its caller too: that frame is a return address, looked up one byte back, inside
//! the call.
//!
//! Test-only, like everything under testing/. Needs root, and is skipped otherwise.

const std = @import("std");
const testing = std.testing;
const agent = @import("agent");
const Server = @import("../../server.zig").Server;
const Controller = @import("../../control/controller.zig").Controller;
const Frame = @import("../../query.zig").Frame;
const burn = @import("../burn.zig").burn;

test "a profile of this process names its functions and their callers (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 8,
        .window_bytes_max = 128 * 1024,
    });
    defer server.deinit(testing.allocator);
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .runs_max = 1 });
    defer controller.deinit(testing.allocator);

    const target = try controller.start(testing.allocator, .{
        .pid = @intCast(std.os.linux.getpid()),
        .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
        .interval_ms = 300,
        .duration_s = 2,
    });
    burn(2300); // Past the end of the run: every window has samples in `burn`.
    _ = controller.join(testing.allocator, target) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    // The tables are built on the server's builder thread: wait for the last one.
    server.builds_wait();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const profile = try server.profile(arena.allocator(), .{
        .target = target,
        .from_unix_ns = 0,
        .to_unix_ns = std.math.maxInt(u64),
    });

    var burn_samples: u64 = 0;
    var burn_samples_caller_named: u64 = 0;
    for (profile.stacks) |stack| {
        const index = burn_index(stack.frames) orelse continue;
        burn_samples += stack.samples;
        if (index + 1 >= stack.frames.len) continue;
        if (stack.frames[index + 1].function != null) burn_samples_caller_named += stack.samples;
    }
    const binaries_count, const binaries_bytes = binaries_used(&server);
    std.debug.print(
        "server e2e: {d} binaries ({d} bytes), {d} samples, {d} stacks, " ++
            "{d} in burn, {d} of those with a named caller\n",
        .{
            binaries_count,     binaries_bytes, profile.samples,
            profile.stacks.len, burn_samples,   burn_samples_caller_named,
        },
    );
    stacks_print(profile.stacks);

    try testing.expect(binaries_count >= 1);
    try testing.expect(profile.stacks.len > 0);
    // The process does little but burn, so most samples are in it...
    try testing.expect(burn_samples * 2 >= profile.samples);
    // ...and nearly all of those name the caller, from a return address.
    try testing.expect(burn_samples_caller_named * 10 >= burn_samples * 9);
}

/// Where `burn` is in the frames, innermost first.
fn burn_index(frames: []const Frame) ?usize {
    for (frames, 0..) |frame, index| {
        const function = frame.function orelse continue;
        if (std.mem.endsWith(u8, function, "burn")) return index;
    }
    return null;
}

fn binaries_used(server: *Server) struct { usize, u64 } {
    server.lock.lock();
    defer server.lock.unlock();
    return .{ server.binaries.count, server.binaries.bytes_used };
}

/// The heaviest stacks, to see what the profile looks like when the test fails.
fn stacks_print(stacks: anytype) void {
    for (stacks[0..@min(stacks.len, 5)], 0..) |stack, index| {
        std.debug.print("  stack {d}: {d} samples:", .{ index, stack.samples });
        for (stack.frames[0..@min(stack.frames.len, 6)]) |frame| {
            std.debug.print(" {s}", .{frame.function orelse "?"});
        }
        std.debug.print("\n", .{});
    }
}
