//! The server: what the agents report.

const std = @import("std");
const protocol = @import("shared").protocol;
const windows_layer = @import("../windows/windows.zig");
const symbols_layer = @import("../symbols/symbols.zig");
const processes_layer = @import("../processes/processes.zig");
const naming = @import("../naming/naming.zig");
const log = @import("../log.zig").server;

const Windows = windows_layer.Windows;
const Symbols = symbols_layer.Symbols;
const Processes = processes_layer.Processes;

pub const TargetId = windows_layer.TargetId;
pub const Query = windows_layer.Query;
pub const Profile = naming.Profile;
pub const Latest = processes_layer.Latest;

pub const Options = struct {
    windows: windows_layer.Options = .{},
    symbols: symbols_layer.Options = .{},
};

pub const Names = enum { as_they_are, all_built };

pub const Server = struct {
    gpa: std.mem.Allocator,
    windows: Windows,
    symbols: Symbols,
    latest: Processes,

    /// Starts the symbols' builder thread: the server must stay at its address until `deinit`.
    pub fn init(server: *Server, gpa: std.mem.Allocator, options: Options) !void {
        errdefer |err| log.err("server failed to start", .{ .cause = err });
        server.gpa = gpa;
        try server.windows.init(gpa, options.windows);
        errdefer server.windows.deinit(gpa);
        try server.symbols.init(gpa, options.symbols);
        errdefer server.symbols.deinit();
        server.latest = .init(gpa);

        const windows = options.windows;
        log.info("server started", .{
            .targets_max = windows.targets_max,
            .windows_per_target_max = windows.windows_per_target_max,
            .window_kib_max = windows.window_bytes_max / 1024,
            .binaries_max = options.symbols.binaries_max,
            .binaries_mib_max = options.symbols.binaries_bytes_max / (1024 * 1024),
        });
    }

    pub fn deinit(server: *Server) void {
        server.latest.deinit();
        server.symbols.deinit();
        server.windows.deinit(server.gpa);
        log.info("server stopped", .{});
        server.* = undefined;
    }

    pub fn feed(server: *Server, pid: u32) !Feed {
        const target = try server.windows.add(server.gpa, pid);
        return .{
            .server = server,
            .target = target,
            .receiver = .init(&server.symbols),
        };
    }

    pub fn watch_take(server: *Server, event: protocol.WatchEvent) !void {
        switch (event) {
            .frame => |frame| try server.latest.put(frame),
            .stopped => {},
        }
    }

    pub fn profile(server: *Server, arena: std.mem.Allocator, query: Query, names: Names) !Profile {
        if (names == .all_built) server.symbols.wait();
        const copied = try server.windows.copy(arena, query);
        const result = try naming.profile(arena, copied, &server.symbols);
        log.debug("profile built", .{
            .target = query.target,
            .windows = copied.windows.len,
            .samples = result.samples,
            .stacks = result.stacks.len,
        });
        return result;
    }

    pub fn processes(server: *Server, arena: std.mem.Allocator) !Latest {
        return server.latest.latest(arena);
    }
};

pub const Feed = struct {
    server: *Server,
    target: TargetId,
    receiver: symbols_layer.Receiver,

    pub fn take(feed: *Feed, event: protocol.RunEvent) !protocol.Answer {
        switch (event) {
            .report => |message| {
                feed.server.windows.put(feed.target, message) catch |err| switch (err) {
                    error.WindowTooLarge => {},
                    else => return err,
                };
                feed.server.symbols.used(message.regions);
                return .none;
            },
            .stopped => return .none,
            else => return feed.receiver.take(event),
        }
    }

    pub fn close(feed: *Feed) void {
        feed.receiver.deinit();
        feed.server.windows.finish(feed.target) catch {};
        feed.* = undefined;
    }
};

const testing = std.testing;
const table_one = @import("../testing/symbols.zig").table_one;
const Message = protocol.Message;

const regions_test = [_]protocol.Region{.{
    .start = 0x7000,
    .end = 0x8000,
    .offset = 0x1000,
    .inode = 1,
    .path = "/bin/app",
    .build_id = "aa",
}};

fn window_test(start_unix_ns: u64, samples_lost: u64, stacks: []const Message.Stack) Message {
    var samples: u64 = 0;
    for (stacks) |stack| samples += stack.samples;
    return .{
        .start_unix_ns = start_unix_ns,
        .duration_ns = 100,
        .pid = 1,
        .sample_hz = 99,
        .samples = samples,
        .samples_lost = samples_lost,
        .regions = &regions_test,
        .stacks = stacks,
    };
}

fn stack_test(samples: u64, user: []const u64) Message.Stack {
    return .{ .samples = samples, .user = user, .kernel = &.{}, .complete = true };
}

fn server_test(server: *Server) !void {
    try server.init(testing.allocator, .{ .windows = .{
        .targets_max = 1,
        .windows_per_target_max = 4,
        .window_bytes_max = 4096,
    } });
}

test "an empty server starts and stops" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{});
    server.deinit();
}

test "a feed's reports become a profile that names the functions and keeps to the range" {
    var server: Server = undefined;
    try server_test(&server);
    defer server.deinit();
    var feed = try server.feed(1);
    defer feed.close();
    const gpa = testing.allocator;
    try server.symbols.binaries.put(gpa, "aa", try table_one(gpa, "work"));

    const first = [_]Message.Stack{stack_test(3, &.{ 0x7110, 0x7220 })};
    const second = [_]Message.Stack{stack_test(4, &.{ 0x7120, 0x7220 })};
    try testing.expectEqual(protocol.Answer.none, try feed.take(.{
        .report = &window_test(100, 1, &first),
    }));
    _ = try feed.take(.{ .report = &window_test(200, 0, &second) });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const all = try server.profile(arena.allocator(), .{ .target = feed.target }, .all_built);
    try testing.expectEqual(@as(u64, 7), all.samples);
    try testing.expectEqual(@as(u64, 1), all.samples_lost);
    try testing.expectEqual(@as(u32, 99), all.sample_hz);
    try testing.expectEqual(@as(usize, 1), all.stacks.len);
    try testing.expectEqualStrings("work", all.stacks[0].frames[0].function.?);
    try testing.expectEqual(@as(?[]const u8, null), all.stacks[0].frames[1].function);
    try testing.expectEqualStrings("/bin/app", all.stacks[0].frames[1].module.?);

    const late_query = Query{ .target = feed.target, .from_unix_ns = 250 };
    const late = try server.profile(arena.allocator(), late_query, .as_they_are);
    try testing.expectEqual(@as(u64, 4), late.samples);

    const unknown = server.profile(arena.allocator(), .{ .target = 999 }, .as_they_are);
    try testing.expectError(error.TargetUnknown, unknown);
}

test "a window too big is counted with the target, and the feed goes on" {
    var server: Server = undefined;
    try server_test(&server);
    defer server.deinit();
    var feed = try server.feed(1);
    defer feed.close();

    const frames = [_]u64{0x7110} ** 1000;
    const big = [_]Message.Stack{stack_test(1, &frames)};
    _ = try feed.take(.{ .report = &window_test(100, 0, &big) });
    const small = [_]Message.Stack{stack_test(2, &.{0x7110})};
    _ = try feed.take(.{ .report = &window_test(200, 0, &small) });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const profile = try server.profile(arena.allocator(), .{ .target = feed.target }, .as_they_are);
    try testing.expectEqual(@as(u64, 1), profile.windows_rejected);
    try testing.expectEqual(@as(u64, 2), profile.samples);
}

test "the watch's frames are kept, newest only" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{});
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u64, 0), (try server.processes(arena.allocator())).frames);

    try server.watch_take(.{ .frame = &.{ .unix_ns = 1, .interval_ns = 0, .processes = &.{} } });
    try server.watch_take(.{ .frame = &.{ .unix_ns = 2, .interval_ns = 9, .processes = &.{} } });
    const latest = try server.processes(arena.allocator());
    try testing.expectEqual(@as(u64, 2), latest.frames);
    try testing.expectEqual(@as(u64, 2), latest.frame.?.unix_ns);
}
