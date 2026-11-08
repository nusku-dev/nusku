//! End to end: the controller profiles this process while it spins in `burn`, and the profile
//! must name `burn` and its caller (a return address). Needs root.

const std = @import("std");
const testing = std.testing;
const protocol = @import("shared").protocol;
const Server = @import("../../server.zig").Server;
const Controller = @import("../../control.zig").Controller;
const Frame = @import("../../naming.zig").Frame;
const burn = @import("../burn.zig").burn;

test "a profile of this process names its functions and their callers (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;

    var server: Server = undefined;
    try server.init(testing.allocator, .{ .windows = .{
        .targets_max = 1,
        .windows_per_target_max = 8,
        .window_bytes_max = 128 * 1024,
    } });
    defer server.deinit();
    var controller: Controller = undefined;
    try controller.init(testing.allocator, &server, .{ .jobs_max = 1 });
    defer controller.deinit();

    const started = controller.start(.{ .profile = .{
        .pid = @intCast(std.os.linux.getpid()),
        .interval_ms = 300,
        .duration_s = 2,
    } }) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    burn(2300); // Past the end of the run: every window has samples in `burn`.
    _ = try controller.wait(started.job);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The tables are built on the symbols' own thread: `all_built` waits for the last one.
    const query = @import("../../windows.zig").Query{ .target = started.target.? };
    const profile = try server.profile(arena.allocator(), query, .all_built);

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
    const stats = server.symbols.stats();
    return .{ stats.binaries, stats.binaries_bytes };
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
