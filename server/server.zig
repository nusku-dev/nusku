//! The server: the windows the agents report, the symbol tables of their binaries, and the
//! profiles built from both. Every call is safe from any thread: one lock guards it all, and
//! is only held for bounded work.

const std = @import("std");
const assert = std.debug.assert;
const agent = @import("agent");
const store = @import("store/store.zig");
const query_file = @import("query.zig");
const lock_file = @import("os/lock.zig");
const builder = @import("symbolize/builder.zig");
const resolve = @import("symbolize/resolve.zig");
const merge = @import("symbolize/merge.zig");
const id_set = @import("store/id_set.zig");
const log_file = @import("log.zig");
const Binaries = @import("store/binaries.zig").Binaries;
const LatestFrame = @import("store/latest_frame.zig").LatestFrame;
const Lookup = @import("symbolize/lookup.zig").Lookup;
const SymbolTable = @import("symbolize/symbol_table.zig").SymbolTable;

const log = log_file.server;
const Lock = lock_file.Lock;
const Condition = lock_file.Condition;
const Received = builder.Received;
const Message = agent.Message;
const ProcessFrame = agent.processes.Frame;

/// Names one profiled process for as long as the server knows it.
pub const TargetId = store.TargetId;

pub const Query = query_file.Query;
pub const Frame = query_file.Frame;
pub const SymbolStack = query_file.SymbolStack;
pub const Profile = query_file.Profile;
pub const Stats = query_file.Stats;

pub const Server = struct {
    pub const Options = struct {
        /// Processes tracked at once. A new one takes the place of the oldest finished one.
        targets_max: u32 = 16,
        /// Windows kept per target; the oldest goes when a new one arrives.
        windows_per_target_max: u32 = 120,
        /// Bytes per window, a multiple of 8. The store takes
        /// targets_max * windows_per_target_max * window_bytes_max.
        window_bytes_max: u32 = 128 * 1024,
        binaries_max: usize = 1024,
        /// All symbol tables together.
        binaries_bytes_max: u64 = 256 * 1024 * 1024,
        /// All uploads together, from their first chunk until their table is built.
        uploads_bytes_max: u64 = 1024 * 1024 * 1024,
    };

    /// One upload per run at most.
    pub const uploads_max = 64;
    const refused_max = 64;

    /// What a run holds while it sends a binary: its claim on the build ID, and its bytes of
    /// the upload budget. Given back by `upload_end` or `upload_abort`.
    pub const Ticket = struct {
        slot: id_set.IdSet(uploads_max).Slot,
        bytes: u64,
    };

    /// Used by the builder thread.
    gpa: std.mem.Allocator,
    lock: Lock,
    store: store.Store,
    binaries: Binaries,
    /// The last frame of the processes watch.
    latest: LatestFrame,

    /// Build IDs being sent now, one per upload.
    claims: id_set.IdSet(uploads_max),
    /// Binaries whose table was too big: sending them again would fail the same way.
    refused: id_set.IdSet(refused_max),
    uploads_bytes_max: u64,
    /// Held by uploads arriving, queued or being built.
    uploads_bytes_used: u64,

    /// Binaries waiting for their symbol table, oldest first.
    builds: builder.Queue,
    /// The build ID being built now, or empty. Owned by the builder thread.
    building: []const u8,
    builds_failed: u64,
    /// Broadcast when a binary is queued, a build ends, or the server stops.
    builds_changed: Condition,
    builds_stopping: bool,
    builder_thread: std.Thread,

    pub fn init(server: *Server, gpa: std.mem.Allocator, options: Options) !void {
        errdefer |err| log.err("server failed to start", .{ .cause = err });
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
        errdefer server.store.deinit(gpa);
        server.binaries = try Binaries.init(gpa, options.binaries_max, options.binaries_bytes_max);
        errdefer server.binaries.deinit(gpa);

        server.gpa = gpa;
        server.lock = .{};
        server.latest = .init(gpa);
        server.claims = .{};
        server.refused = .{};
        server.uploads_bytes_max = options.uploads_bytes_max;
        server.uploads_bytes_used = 0;
        server.builds = .{};
        server.building = &.{};
        server.builds_failed = 0;
        server.builds_changed = .{};
        server.builds_stopping = false;
        // Last: the thread reads the server as soon as it runs.
        server.builder_thread = try std.Thread.spawn(.{}, builder_main, .{server});

        log.info("server started", .{
            .targets_max = options.targets_max,
            .windows_per_target_max = options.windows_per_target_max,
            .window_kib_max = options.window_bytes_max / 1024,
            .binaries_max = options.binaries_max,
            .binaries_mib_max = options.binaries_bytes_max / (1024 * 1024),
            .uploads_mib_max = options.uploads_bytes_max / (1024 * 1024),
        });
    }

    /// Stops the builder, after the build in progress, and frees everything. Binaries still
    /// queued are dropped.
    pub fn deinit(server: *Server, gpa: std.mem.Allocator) void {
        server.lock.lock();
        server.builds_stopping = true;
        server.builds_changed.broadcast();
        server.lock.unlock();
        server.builder_thread.join();

        log.info("server stopped", .{
            .targets = server.store.count,
            .binaries = server.binaries.count,
            .binaries_mib = server.binaries.bytes_used / (1024 * 1024),
            .builds_failed = server.builds_failed,
            .builds_dropped = server.builds.count,
        });
        server.builds.deinit(gpa);
        server.store.deinit(gpa);
        server.binaries.deinit(gpa);
        server.latest.deinit();
        server.* = undefined;
    }

    pub fn stats(server: *Server) Stats {
        server.lock.lock();
        defer server.lock.unlock();
        return .{
            .binaries = server.binaries.count,
            .binaries_bytes = server.binaries.bytes_used,
            .builds_pending = server.builds.count + @intFromBool(server.building.len > 0),
            .builds_failed = server.builds_failed,
            .uploads_bytes = server.uploads_bytes_used,
        };
    }

    // ---------------------------------------------------------------------- targets, windows

    /// Registers a process and allocates its windows: once per process, not per report.
    pub fn target_add(server: *Server, gpa: std.mem.Allocator, pid: u32) !TargetId {
        const target = target: {
            server.lock.lock();
            defer server.lock.unlock();
            break :target server.store.target_add(gpa, pid) catch |err| {
                log.warn("process not tracked", .{
                    .pid = pid,
                    .targets_max = server.store.targets.len,
                    .cause = err,
                });
                return err;
            };
        };
        log.debug("target added", .{ .target = target, .pid = pid });
        return target;
    }

    /// No more reports will come. The windows stay for queries until the room is needed.
    pub fn target_finish(server: *Server, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.target_finish(target);
        log.debug("target finished", .{ .target = target });
    }

    pub fn target_remove(server: *Server, gpa: std.mem.Allocator, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.target_remove(gpa, target);
        log.debug("target removed", .{ .target = target });
    }

    /// Keeps a copy of `message` as the target's newest window: the caller keeps `message`.
    /// Does not allocate.
    pub fn ingest(server: *Server, target: TargetId, message: *const Message) !void {
        server.lock.lock();
        defer server.lock.unlock();
        server.store.ingest(target, message) catch |err| {
            if (err == error.WindowTooLarge) server.window_lost_log(target);
            return err;
        };
        // The tables this window needs count as used, so eviction takes those nobody needs.
        for (message.regions) |region| {
            const build_id = region.build_id orelse continue;
            _ = server.binaries.get(build_id);
        }
    }

    /// A report the run could not copy: counted as a lost window of the target.
    pub fn window_dropped(server: *Server, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.window_dropped(target);
        server.window_lost_log(target);
    }

    /// Logged for a target's first lost window only; profiles count them all.
    fn window_lost_log(server: *Server, target: TargetId) void {
        if (server.store.target_find(target).?.windows_rejected != 1) return;
        log.warn("window too big to keep: its samples are lost", .{
            .target = target,
            .window_kib_max = server.store.ring_options.window_bytes_max / 1024,
        });
    }

    // ---------------------------------------------------------------------- processes

    pub fn processes_ingest(server: *Server, frame: *const ProcessFrame) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.latest.put(frame);
    }

    /// The last frame of the processes watch, copied into `arena`. Null before the first.
    pub fn processes(server: *Server, arena: std.mem.Allocator) !?ProcessFrame {
        server.lock.lock();
        defer server.lock.unlock();
        return server.latest.get(arena);
    }

    /// Frames received so far: for a client waiting for the next one.
    pub fn processes_frames(server: *Server) u64 {
        server.lock.lock();
        defer server.lock.unlock();
        return server.latest.frames;
    }

    // ---------------------------------------------------------------------- binaries

    /// True when the agent need not send this binary: the server has its table, will have it,
    /// or refused it before.
    pub fn binary_known(server: *Server, build_id: []const u8) bool {
        server.lock.lock();
        defer server.lock.unlock();
        return server.binary_known_locked(build_id);
    }

    fn binary_known_locked(server: *const Server, build_id: []const u8) bool {
        return server.binaries.has(build_id) or server.builds.has(build_id) or
            std.mem.eql(u8, server.building, build_id) or server.claims.has(build_id) or
            server.refused.has(build_id);
    }

    /// Claims `build_id` and reserves `bytes` of the upload budget for a run to send it.
    pub fn upload_start(
        server: *Server,
        build_id: []const u8,
        path: []const u8,
        bytes: u64,
    ) error{ Malformed, AlreadyKnown, UploadsFull }!Ticket {
        if (build_id.len == 0 or build_id.len > id_set.id_bytes_max) return error.Malformed;

        server.lock.lock();
        defer server.lock.unlock();
        if (server.binary_known_locked(build_id)) return error.AlreadyKnown;
        const room = bytes <= server.uploads_bytes_max - server.uploads_bytes_used;
        const slot = (if (room) server.claims.add(build_id) else null) orelse {
            log.warn("binary refused: the server is receiving too much at once", .{
                .path = path,
                .kib = log_file.kib(bytes),
                .uploads_kib = log_file.kib(server.uploads_bytes_used),
                .uploads_kib_max = log_file.kib(server.uploads_bytes_max),
                .uploads = server.claims.count(),
                .uploads_max = uploads_max,
            });
            return error.UploadsFull;
        };
        server.uploads_bytes_used += bytes;
        return .{ .slot = slot, .bytes = bytes };
    }

    /// Gives back the claim and the bytes of an upload that did not finish.
    pub fn upload_abort(server: *Server, ticket: Ticket) void {
        server.lock.lock();
        defer server.lock.unlock();
        server.claims.remove(ticket.slot);
        server.uploads_release(ticket.bytes);
    }

    /// Queues a whole binary for the builder; its bytes stay reserved until its table is built.
    /// Takes `received`, whatever it returns.
    pub fn upload_end(server: *Server, ticket: Ticket, received: Received) error{QueueFull}!void {
        var owned = received;
        owned.reserved = ticket.bytes;

        server.lock.lock();
        defer server.lock.unlock();
        server.claims.remove(ticket.slot);
        try server.received_queue(owned);
    }

    /// `upload_end` for a binary from outside the upload budget.
    pub fn binary_received(server: *Server, received: Received) error{QueueFull}!void {
        assert(received.reserved == 0);
        server.lock.lock();
        defer server.lock.unlock();
        try server.received_queue(received);
    }

    /// Takes a finished symbol table.
    pub fn binary_put(
        server: *Server,
        gpa: std.mem.Allocator,
        build_id: []const u8,
        table: SymbolTable,
    ) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.binaries.put(gpa, build_id, table);
    }

    /// Waits until every binary received so far has its table, or failed to get one.
    pub fn builds_wait(server: *Server) void {
        server.lock.lock();
        defer server.lock.unlock();
        while (server.builds.count > 0 or server.building.len > 0) {
            server.builds_changed.wait(&server.lock);
        }
    }

    fn received_queue(server: *Server, received: Received) error{QueueFull}!void {
        var owned = received;
        if (server.binary_known_locked(owned.id)) {
            server.received_free(&owned); // Another run sent it first.
            return;
        }
        server.builds.push(owned) catch |err| {
            log.warn("binary dropped: too many waiting for their symbol table", .{
                .path = owned.path,
                .waiting_max = builder.Queue.items_max,
            });
            server.received_free(&owned);
            return err;
        };
        server.builds_changed.broadcast();
    }

    fn received_free(server: *Server, received: *Received) void {
        server.uploads_release(received.reserved);
        received.deinit(server.gpa);
    }

    fn uploads_release(server: *Server, bytes: u64) void {
        assert(bytes <= server.uploads_bytes_used);
        server.uploads_bytes_used -= bytes;
    }

    /// Builds the queued tables one at a time, without the lock, until the server stops.
    fn builder_main(server: *Server) void {
        server.lock.lock();
        defer server.lock.unlock();
        while (true) {
            while (server.builds.count == 0 and !server.builds_stopping) {
                server.builds_changed.wait(&server.lock);
            }
            if (server.builds_stopping) return;

            var received = server.builds.pop().?;
            server.building = received.id;
            server.lock.unlock();
            const built = received.build(server.gpa);
            server.lock.lock();

            server.built_keep(&received, built);
            server.building = &.{};
            server.received_free(&received);
            server.builds_changed.broadcast();
        }
    }

    fn built_keep(server: *Server, received: *const Received, built: anyerror!SymbolTable) void {
        const functions = if (built) |table| table.count else |_| 0;
        const kib = if (built) |table| log_file.kib(table.bytes()) else |_| 0;
        const kept = if (built) |table|
            server.binaries.put(server.gpa, received.id, table)
        else |err|
            err;
        if (kept) |_| {
            log.debug("symbol table ready", .{
                .path = received.path,
                .functions = functions,
                .kib = kib,
            });
        } else |err| {
            server.builds_failed += 1;
            // Too big now is too big next time: no run needs to send it again.
            if (err == error.TooLarge) server.refused.add_over_oldest(received.id);
            log.warn("no symbol table: its frames will stay unnamed", .{
                .path = received.path,
                .kib = kib,
                .cause = err,
            });
        }
    }

    // ---------------------------------------------------------------------- queries

    /// The windows of the target that overlap the time range, their frames named and equal
    /// stacks merged, in `arena`. An evicted table costs a frame its name, nothing worse.
    pub fn profile(server: *Server, arena: std.mem.Allocator, query: Query) !Profile {
        const windows, const windows_rejected = try server.windows_copy(arena, query);

        var stacks_count: usize = 0;
        for (windows) |window| stacks_count += window.stacks.len;
        const stacks = try arena.alloc(SymbolStack, stacks_count);

        // On the heap: its cache is large.
        const lookup = try arena.create(Lookup);
        lookup.* = .{ .lock = &server.lock, .binaries = &server.binaries };
        var result = Profile{
            .sample_hz = 0,
            .samples = 0,
            .samples_lost = 0,
            .windows_rejected = windows_rejected,
            .stacks = &.{},
        };
        var filled: usize = 0;
        for (windows) |*window| {
            const resolved = try resolve.window_resolve(arena, lookup, window);
            @memcpy(stacks[filled..][0..resolved.len], resolved);
            filled += resolved.len;
            result.samples += window.samples;
            result.samples_lost += window.samples_lost;
            result.sample_hz = window.sample_hz;
        }
        assert(filled == stacks.len);

        result.stacks = merge.stacks_merge(stacks);
        log.debug("profile built", .{
            .target = query.target,
            .windows = windows.len,
            .samples = result.samples,
            .stacks_seen = stacks.len,
            .stacks = result.stacks.len,
        });
        return result;
    }

    /// The windows of the query, oldest first, copied into `arena`, and how many the target
    /// lost.
    fn windows_copy(
        server: *Server,
        arena: std.mem.Allocator,
        query: Query,
    ) !struct { []Message, u64 } {
        server.lock.lock();
        defer server.lock.unlock();

        const target = server.store.target_find(query.target) orelse return error.TargetUnknown;
        const ring = &target.ring;

        var count: usize = 0;
        for (0..ring.count) |age| {
            if (window_overlaps(ring.window_get(@intCast(age)), query)) count += 1;
        }
        const windows = try arena.alloc(Message, count);

        var filled: usize = 0;
        var age: u32 = ring.count;
        while (age > 0) {
            age -= 1;
            const window = ring.window_get(age);
            if (!window_overlaps(window, query)) continue;
            windows[filled] = try window.clone(arena);
            filled += 1;
        }
        assert(filled == count);
        return .{ windows, target.windows_rejected };
    }
};

fn window_overlaps(window: *const Message, query: Query) bool {
    const end_unix_ns = window.start_unix_ns +| window.duration_ns;
    return window.start_unix_ns < query.to_unix_ns and end_unix_ns > query.from_unix_ns;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const elf = @import("shared").elf;

/// The symtab and strtab of one function, `function`, at address 0x401100 .. 0x401140.
fn symbols_one(function: *const [4]u8) struct { [24]u8, [6]u8 } {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    return .{ sym, ("\x00" ++ function ++ "\x00").* };
}

/// File offset 0x1000 is address 0x401000: the function is at file offset 0x1100.
const segments_test = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};

fn table_one(gpa: std.mem.Allocator, function: *const [4]u8) !SymbolTable {
    const sym, const strtab = symbols_one(function);
    return SymbolTable.init(gpa, .{
        .segments = &segments_test,
        .symtab = &sym,
        .strtab = &strtab,
    });
}

/// The same function as a binary handed over by an upload.
fn received_one(gpa: std.mem.Allocator, id: []const u8, function: *const [4]u8) !Received {
    const sym, const strtab = symbols_one(function);
    var starts = std.EnumArray(agent.binary.Section, usize).initFill(0);
    var sizes = std.EnumArray(agent.binary.Section, usize).initFill(0);
    starts.set(.strtab, sym.len);
    sizes.set(.symtab, sym.len);
    sizes.set(.strtab, strtab.len);
    return .{
        .id = try gpa.dupe(u8, id),
        .path = try gpa.dupe(u8, "/bin/app"),
        .segments = try gpa.dupe(elf.Segment, &segments_test),
        .data = try std.mem.concat(gpa, u8, &.{ &sym, &strtab }),
        .starts = starts,
        .sizes = sizes,
    };
}

/// /bin/app, at 0x7000 from file offset 0x1000: the function's file offset 0x1100 is 0x7100.
const regions_test = [_]agent.Region{.{
    .start = 0x7000,
    .end = 0x8000,
    .offset = 0x1000,
    .inode = 1,
    .path = "/bin/app",
    .build_id = "aa",
}};

fn stack_test(samples: u64, user: []const u64) Message.Stack {
    return .{ .samples = samples, .user = user, .kernel = &.{}, .complete = true };
}

/// A window of 100 ns from `start_unix_ns`; its samples are those of its stacks.
fn window_test(
    start_unix_ns: u64,
    samples_lost: u64,
    regions: []const agent.Region,
    stacks: []const Message.Stack,
) Message {
    var samples: u64 = 0;
    for (stacks) |stack| samples += stack.samples;
    return .{
        .start_unix_ns = start_unix_ns,
        .duration_ns = 100,
        .pid = 1,
        .sample_hz = 99,
        .samples = samples,
        .samples_lost = samples_lost,
        .regions = regions,
        .stacks = stacks,
    };
}

fn query_test(target: TargetId, from_unix_ns: u64, to_unix_ns: u64) Query {
    return .{ .target = target, .from_unix_ns = from_unix_ns, .to_unix_ns = to_unix_ns };
}

fn name_of(server: *Server, build_id: []const u8, offset: u64) ?[]const u8 {
    server.lock.lock();
    defer server.lock.unlock();
    const table = server.binaries.get(build_id) orelse return null;
    return (table.lookup(offset) orelse return null).name;
}

test "an empty server starts and stops" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{});
    server.deinit(testing.allocator);
}

test "a server keeps what a registered target ingests, and refuses the rest" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);

    const stacks = [_]Message.Stack{stack_test(1, &.{1})};
    const message = window_test(1, 0, &.{}, &stacks);
    try testing.expectError(error.TargetUnknown, server.ingest(1, &message));
    const target = try server.target_add(testing.allocator, 100);
    try server.ingest(target, &message);
    try testing.expectError(error.TargetsFull, server.target_add(testing.allocator, 200));
}

test "a binary is known once its table is put" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{});
    defer server.deinit(testing.allocator);

    try testing.expect(!server.binary_known("some build id"));
    const table = try SymbolTable.init(testing.allocator, .{ .segments = &.{} });
    try server.binary_put(testing.allocator, "some build id", table);
    try testing.expect(server.binary_known("some build id"));
}

test "a profile names the functions, merges the windows and keeps to the time range" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 4,
        .window_bytes_max = 4096,
    });
    defer server.deinit(testing.allocator);
    const target = try server.target_add(testing.allocator, 1);
    try server.binary_put(testing.allocator, "aa", try table_one(testing.allocator, "work"));

    // The leaf is in `work`, at two instructions; the caller has no name.
    const first = [_]Message.Stack{stack_test(3, &.{ 0x7110, 0x7220 })};
    const second = [_]Message.Stack{stack_test(4, &.{ 0x7120, 0x7220 })};
    try server.ingest(target, &window_test(100, 1, &regions_test, &first));
    try server.ingest(target, &window_test(200, 0, &regions_test, &second));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const all = try server.profile(arena.allocator(), query_test(target, 0, 1000));
    try testing.expectEqual(@as(u64, 7), all.samples);
    try testing.expectEqual(@as(u64, 1), all.samples_lost);
    try testing.expectEqual(@as(u32, 99), all.sample_hz);
    try testing.expectEqual(@as(usize, 1), all.stacks.len);
    try testing.expectEqual(@as(u64, 7), all.stacks[0].samples);
    try testing.expectEqualStrings("work", all.stacks[0].frames[0].function.?);
    try testing.expectEqual(@as(?[]const u8, null), all.stacks[0].frames[1].function);
    try testing.expectEqualStrings("/bin/app", all.stacks[0].frames[1].module.?);

    const late = try server.profile(arena.allocator(), query_test(target, 250, 1000));
    try testing.expectEqual(@as(u64, 4), late.samples);
    try testing.expectEqual(@as(u64, 4), late.stacks[0].samples);

    const none = try server.profile(arena.allocator(), query_test(target, 1000, 2000));
    try testing.expectEqual(@as(usize, 0), none.stacks.len);
    try testing.expectEqual(@as(u64, 0), none.samples);

    try testing.expectEqual(@as(u64, 0), all.windows_rejected);
    try server.window_dropped(target);
    const after = try server.profile(arena.allocator(), query_test(target, 0, 1000));
    try testing.expectEqual(@as(u64, 1), after.windows_rejected);

    const unknown = query_test(999, 0, 1000);
    try testing.expectError(error.TargetUnknown, server.profile(arena.allocator(), unknown));
}

test "a received binary is known at once, and named once the builder is done" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1 });
    defer server.deinit(testing.allocator);

    try server.binary_received(try received_one(testing.allocator, "aa", "work"));
    try testing.expect(server.binary_known("aa"));
    // The same binary from another run is dropped.
    try server.binary_received(try received_one(testing.allocator, "aa", "else"));

    server.builds_wait();
    try testing.expectEqualStrings("work", name_of(&server, "aa", 0x1100).?);
    const stats = server.stats();
    try testing.expectEqual(@as(usize, 1), stats.binaries);
    try testing.expect(stats.binaries_bytes > 0);
    try testing.expectEqual(@as(usize, 0), stats.builds_pending);
    try testing.expectEqual(@as(u64, 0), stats.builds_failed);
}

test "a table too big to keep is counted, refused for later, and the server goes on" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1, .binaries_bytes_max = 8 });
    defer server.deinit(testing.allocator);

    try server.binary_received(try received_one(testing.allocator, "aa", "work"));
    server.builds_wait();
    try testing.expectEqual(@as(u64, 1), server.builds_failed);
    try testing.expect(server.binary_known("aa"));
    try testing.expectEqual(@as(usize, 0), server.binaries.count);
}

test "binaries still queued when the server stops are freed" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1 });
    for (0..8) |index| {
        var id: [2]u8 = .{ 'a', @intCast('a' + index) };
        try server.binary_received(try received_one(testing.allocator, &id, "work"));
    }
    server.deinit(testing.allocator); // The testing allocator would report a leak.
}

test "uploads share one budget, held from the first chunk until the table is built" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1, .uploads_bytes_max = 100 });
    defer server.deinit(testing.allocator);

    const first = try server.upload_start("aa", "/a", 60);
    try testing.expectError(error.UploadsFull, server.upload_start("bb", "/b", 41));
    try testing.expectError(error.AlreadyKnown, server.upload_start("aa", "/a", 1));
    const second = try server.upload_start("bb", "/b", 40);
    try testing.expectEqual(@as(u64, 100), server.uploads_bytes_used);

    // An abort gives its bytes back at once; an end, once the table is built.
    server.upload_abort(second);
    try testing.expectEqual(@as(u64, 60), server.uploads_bytes_used);
    try testing.expect(!server.binary_known("bb"));
    try server.upload_end(first, try received_one(testing.allocator, "aa", "work"));
    server.builds_wait();
    try testing.expectEqual(@as(u64, 0), server.uploads_bytes_used);
    try testing.expectEqualStrings("work", name_of(&server, "aa", 0x1100).?);
}

test "a table that arriving windows need outlives one that nothing needs" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .window_bytes_max = 4096,
        .binaries_max = 2,
    });
    defer server.deinit(testing.allocator);
    const target = try server.target_add(testing.allocator, 1);

    try server.binary_put(testing.allocator, "aa", try table_one(testing.allocator, "work"));
    try server.binary_put(testing.allocator, "bb", try table_one(testing.allocator, "rest"));
    // A window needs "aa": now "bb" is the least recently used.
    const stacks = [_]Message.Stack{stack_test(1, &.{0x7110})};
    try server.ingest(target, &window_test(100, 0, &regions_test, &stacks));

    try server.binary_put(testing.allocator, "cc", try table_one(testing.allocator, "more"));
    try testing.expect(server.binary_known("aa"));
    try testing.expect(!server.binary_known("bb"));
}
