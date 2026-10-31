const std = @import("std");
const assert = std.debug.assert;
const agent = @import("agent");
const store = @import("store/store.zig");
const Lock = @import("os/lock.zig").Lock;

const Message = agent.Message;

/// Names one profiled process for as long as the server knows it.
pub const TargetId = store.TargetId;

pub const Frame = struct {
    address: u64,
    kernel: bool,
    /// Null when the address could not be resolved: the report still shows the raw address.
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    /// The binary or library the address is in.
    module: ?[]const u8 = null,
};

pub const SymbolStack = struct {
    samples: u64,
    /// Innermost frame first, kernel frames before user frames.
    frames: []const Frame,
    complete: bool,
};

pub const Profile = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    stacks: []const SymbolStack,
};

pub const Query = struct {
    target: TargetId,
    from_unix_ns: u64,
    to_unix_ns: u64,
};

pub const Server = struct {
    pub const Options = struct {
        /// Processes the server tracks at once.
        targets_max: u32 = 16,
        /// Windows kept per target: the oldest is dropped when a new one arrives.
        windows_per_target_max: u32 = 120,
        /// Bytes one window may take (multiple of 8). With the two limits above this fixes
        /// the memory of the server: targets_max * windows_per_target_max * window_bytes_max.
        window_bytes_max: u32 = 128 * 1024,
    };

    store: store.Store,
    lock: Lock,

    pub fn init(server: *Server, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.targets_max > 0);
        assert(options.windows_per_target_max > 0);
        assert(options.window_bytes_max > 0);
        assert(options.window_bytes_max % 8 == 0);

        try server.store.init(gpa, .{
            .targets_max = options.targets_max,
            .ring = .{
                .windows_max = options.windows_per_target_max,
                .window_bytes_max = options.window_bytes_max,
            },
        });

        server.lock = .{};
    }

    /// Registers a process the server will receive reports for. Allocates the target's
    /// windows: call it once per process, not per report. Safe to call from any thread.
    pub fn target_add(server: *Server, gpa: std.mem.Allocator, pid: u32) !TargetId {
        server.lock.lock();
        defer server.lock.unlock();
        return server.store.target_add(gpa, pid);
    }

    /// Where agents deliver reports. Safe to call from any thread. Copies what it keeps,
    /// so the caller may free `message` when this returns. Does not allocate, and holds the
    /// lock only for one bounded copy (at most `window_bytes_max`).
    pub fn ingest(server: *Server, target: TargetId, message: *const Message) !void {
        server.lock.lock();
        defer server.lock.unlock();
        return server.store.ingest(target, message);
    }

    /// The symbolized profile of one target over a time range. Everything lives in `arena`.
    pub fn profile(server: *Server, arena: std.mem.Allocator, query: Query) !Profile {
        _ = .{ server, arena, query };
        return error.NotImplemented;
    }

    pub fn deinit(server: *Server, gpa: std.mem.Allocator) void {
        server.store.deinit(gpa);
        server.* = undefined;
    }
};

test "an empty server starts and stops" {
    var server: Server = undefined;
    try server.init(std.testing.allocator, .{});
    server.deinit(std.testing.allocator);
}

test "a server keeps what a registered target ingests, and refuses the rest" {
    const stacks = [_]Message.Stack{.{ .samples = 1, .user = &.{1}, .kernel = &.{}, .complete = true }};
    const message = Message{
        .start_unix_ns = 1,
        .duration_ns = 1,
        .pid = 100,
        .sample_hz = 99,
        .samples = 1,
        .samples_lost = 0,
        .regions = &.{},
        .stacks = &stacks,
    };

    var server: Server = undefined;
    try server.init(std.testing.allocator, .{ .targets_max = 1, .windows_per_target_max = 2, .window_bytes_max = 1024 });
    defer server.deinit(std.testing.allocator);

    try std.testing.expectError(error.TargetUnknown, server.ingest(1, &message));
    const target = try server.target_add(std.testing.allocator, 100);
    try server.ingest(target, &message);
    try std.testing.expectError(error.TargetsFull, server.target_add(std.testing.allocator, 200));
}
