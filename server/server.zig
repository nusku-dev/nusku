//! The server: what the agents report (a ring of windows per target), the symbols of their
//! binaries, and the profiles built from both. Every call is safe from any thread: one lock
//! guards the store and the binaries, and is held only for bounded work.

const std = @import("std");
const assert = std.debug.assert;
const agent = @import("agent");
const store = @import("store/store.zig");
const query_file = @import("query.zig");
const lock_file = @import("os/lock.zig");
const builder = @import("symbolize/builder.zig");
const resolve = @import("symbolize/resolve.zig");
const merge = @import("symbolize/merge.zig");
const Binaries = @import("store/binaries.zig").Binaries;
const id_set = @import("store/id_set.zig");
const log_file = @import("log.zig");
const log = log_file.server;
const SymbolTable = @import("symbolize/symbol_table.zig").SymbolTable;

const Lock = lock_file.Lock;
const Condition = lock_file.Condition;
const Received = builder.Received;
const Message = agent.Message;

/// Names one profiled process for as long as the server knows it.
pub const TargetId = store.TargetId;

pub const Query = query_file.Query;
pub const Frame = query_file.Frame;
pub const SymbolStack = query_file.SymbolStack;
pub const Profile = query_file.Profile;
pub const Stats = query_file.Stats;

/// Names addresses for `resolve`, for one query. The lock is taken for one table lookup at a
/// time, and the name is copied out before it is let go.
///
/// The same addresses come back again and again in a profile (every stack through a call site
/// has its return address), so answers are kept in a small cache. A build ID and a file offset
/// name the same function forever, so a cached answer stays right even if the table goes.
const Lookup = struct {
    server: *Server,
    cache: [cache_size]Slot = @splat(.{}),

    const cache_size = 1024;

    const Slot = struct {
        /// Points into the query's windows, which outlive the lookup. Empty: an unused slot.
        build_id: []const u8 = &.{},
        offset: u64 = 0,
        name: ?[]const u8 = null,
    };

    pub fn name(
        lookup: *Lookup,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        assert(build_id.len > 0);

        var hasher = std.hash.Wyhash.init(offset);
        hasher.update(build_id);
        const slot = &lookup.cache[hasher.final() % cache_size];
        if (slot.offset == offset and std.mem.eql(u8, slot.build_id, build_id)) return slot.name;

        const found = try lookup.name_find(arena, build_id, offset);
        slot.* = .{ .build_id = build_id, .offset = offset, .name = found };
        return found;
    }

    fn name_find(
        lookup: *Lookup,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        lookup.server.lock.lock();
        defer lookup.server.lock.unlock();

        const table = lookup.server.binaries.get(build_id) orelse return null;
        const hit = table.lookup(offset) orelse return null;
        return try arena.dupe(u8, hit.name);
    }
};

pub const Server = struct {
    pub const Options = struct {
        /// Processes the server tracks at once. When a new one needs room, the oldest finished
        /// one is dropped, windows and all.
        targets_max: u32 = 16,
        /// Windows kept per target: the oldest is dropped when a new one arrives.
        windows_per_target_max: u32 = 120,
        /// Bytes one window may take (multiple of 8). With the two limits above this fixes
        /// the memory of the server: targets_max * windows_per_target_max * window_bytes_max.
        window_bytes_max: u32 = 128 * 1024,
        /// What the symbol tables of all binaries may take together.
        binaries_bytes_max: u64 = 256 * 1024 * 1024,
        /// How many binaries the server keeps symbols for, at most.
        binaries_max: usize = 1024,
        /// What the buffers of every upload may take together, from the first chunk until the
        /// table is built: arriving, queued and being built.
        uploads_bytes_max: u64 = 1024 * 1024 * 1024,
    };

    /// Uploads at once: one per run is all a run can have.
    pub const uploads_max = 64;
    /// Binaries whose table could not be built, remembered so no run sends them again.
    const refused_max = 64;

    /// What a run holds while it sends a binary: the build ID it claimed, and the bytes it
    /// reserved. Given back with `upload_end` or `upload_abort`.
    pub const Ticket = struct {
        slot: id_set.IdSet(uploads_max).Slot,
        bytes: u64,
    };

    /// The builder thread allocates and frees with it.
    gpa: std.mem.Allocator,
    store: store.Store,
    lock: Lock,
    binaries: Binaries,

    /// Binaries whose symbol table is still to be built, oldest first.
    builds: builder.Queue,
    /// The build ID of the table being built now, or empty. Owned by the builder thread.
    building: []const u8,
    /// Tables that could not be built or kept (too big for the budget, out of memory).
    builds_failed: u64,
    /// The build IDs being sent now, one slot per upload.
    claims: id_set.IdSet(uploads_max),
    /// Binaries too big to keep: sending them again would fail the same way.
    refused: id_set.IdSet(refused_max),
    uploads_bytes_max: u64,
    /// Reserved by uploads that are arriving, queued or being built.
    uploads_bytes_used: u64,
    /// Broadcast when a binary is queued, when a build ends, and when the server stops.
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
        server.builds = .{};
        server.building = &.{};
        server.builds_failed = 0;
        server.claims = .{};
        server.refused = .{};
        server.uploads_bytes_max = options.uploads_bytes_max;
        server.uploads_bytes_used = 0;
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

    /// Registers a process the server will receive reports for. Allocates the target's
    /// windows: call it once per process, not per report. Safe to call from any thread.
    pub fn target_add(server: *Server, gpa: std.mem.Allocator, pid: u32) !TargetId {
        const target = target: {
            server.lock.lock();
            defer server.lock.unlock();
            break :target server.store.target_add(gpa, pid) catch |err| {
                // Full: every target is still running, none can make room.
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

    /// No more reports will come for the target. Its windows can still be queried, until its
    /// room is needed for a new target.
    pub fn target_finish(server: *Server, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.target_finish(target);
        log.debug("target finished", .{ .target = target });
    }

    /// Drops the target and its windows now.
    pub fn target_remove(server: *Server, gpa: std.mem.Allocator, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.target_remove(gpa, target);
        log.debug("target removed", .{ .target = target });
    }

    /// A report the run could not copy: the target's profile counts it as lost.
    pub fn window_dropped(server: *Server, target: TargetId) !void {
        server.lock.lock();
        defer server.lock.unlock();
        try server.store.window_dropped(target);
        server.window_lost_log(target);
    }

    /// The first window a target loses, too big for the run to copy or for the store to keep.
    /// Once per target: the rest would repeat it every report, and profiles count every one
    /// (`windows_rejected`). Holds the lock.
    fn window_lost_log(server: *Server, target: TargetId) void {
        if (server.store.target_find(target).?.windows_rejected != 1) return;
        log.warn("window too big to keep: its samples are lost", .{
            .target = target,
            .window_kib_max = server.store.ring_options.window_bytes_max / 1024,
        });
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

    /// Where agents deliver reports. Safe to call from any thread. Copies what it keeps,
    /// so the caller may free `message` when this returns. Does not allocate, and holds the
    /// lock only for one bounded copy (at most `window_bytes_max`).
    pub fn ingest(server: *Server, target: TargetId, message: *const Message) !void {
        server.lock.lock();
        defer server.lock.unlock();
        server.store.ingest(target, message) catch |err| {
            if (err == error.WindowTooLarge) server.window_lost_log(target);
            return err;
        };

        // The tables this window will need count as used now, so the ones that go first
        // when room is short are those no recent window needs.
        for (message.regions) |region| {
            const build_id = region.build_id orelse continue;
            _ = server.binaries.get(build_id);
        }
    }

    /// True when the server has the symbols of this build ID, or will have them once its table is
    /// built: the agent then skips the upload.
    pub fn binary_known(server: *Server, build_id: []const u8) bool {
        server.lock.lock();
        defer server.lock.unlock();
        return server.binary_known_locked(build_id);
    }

    /// Known, about to be (queued, being built, being sent by a run), or refused before.
    fn binary_known_locked(server: *const Server, build_id: []const u8) bool {
        return server.binaries.has(build_id) or server.builds.has(build_id) or
            std.mem.eql(u8, server.building, build_id) or server.claims.has(build_id) or
            server.refused.has(build_id);
    }

    /// Lets a run send the binary `build_id`, whose sections take `bytes`. `AlreadyKnown` when
    /// the server has it or another run is sending it; `UploadsFull` when the uploads together
    /// would take more than the budget.
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

    /// The upload stopped before its end: the claim and the bytes are given back.
    pub fn upload_abort(server: *Server, ticket: Ticket) void {
        server.lock.lock();
        defer server.lock.unlock();
        server.claims.remove(ticket.slot);
        server.uploads_release(ticket.bytes);
    }

    /// The upload arrived whole: it goes to the builder, and keeps its bytes until its table is
    /// built. Owns `received` from then on, whatever it returns.
    pub fn upload_end(server: *Server, ticket: Ticket, received: Received) error{QueueFull}!void {
        var owned = received;
        owned.reserved = ticket.bytes;

        server.lock.lock();
        defer server.lock.unlock();
        server.claims.remove(ticket.slot);
        try server.received_queue(owned);
    }

    /// `upload_end` without a ticket: for a binary that comes from elsewhere, outside the
    /// upload budget.
    pub fn binary_received(server: *Server, received: Received) error{QueueFull}!void {
        assert(received.reserved == 0);
        server.lock.lock();
        defer server.lock.unlock();
        try server.received_queue(received);
    }

    fn received_queue(server: *Server, received: Received) error{QueueFull}!void {
        var owned = received;
        if (server.binary_known_locked(owned.id)) {
            server.received_free(&owned); // Sent by another run first.
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

    /// Waits until every binary received so far has its table (or failed to get one). For
    /// tests, and for a caller that wants a query to see every name it can.
    pub fn builds_wait(server: *Server) void {
        server.lock.lock();
        defer server.lock.unlock();
        while (server.builds.count > 0 or server.building.len > 0) {
            server.builds_changed.wait(&server.lock);
        }
    }

    /// Builds the tables of the queued binaries, one at a time, until the server stops. The
    /// build itself runs without the lock.
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
                // Too big now is too big the next time: no run needs to send it again.
                if (err == error.TooLarge) server.refused.add_over_oldest(received.id);
                log.warn("no symbol table: its frames will stay unnamed", .{
                    .path = received.path,
                    .kib = kib,
                    .cause = err,
                });
            }
            server.building = &.{};
            server.received_free(&received);
            server.builds_changed.broadcast();
        }
    }

    /// Takes a finished symbol table. Holds the lock.
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

    /// The profile of one target over a time range: the windows that overlap it, with their
    /// stacks named and equal stacks merged. Everything lives in `arena`.
    ///
    /// The lock is held to copy the windows, and then for one name lookup at a time. A table
    /// that is evicted while the query runs costs a frame its name, nothing worse.
    pub fn profile(server: *Server, arena: std.mem.Allocator, query: Query) !Profile {
        const windows, const windows_rejected = try server.windows_copy(arena, query);

        var stacks_count: usize = 0;
        for (windows) |window| stacks_count += window.stacks.len;
        const stacks = try arena.alloc(SymbolStack, stacks_count);

        // Large (its cache): kept off the stack.
        const lookup = try arena.create(Lookup);
        lookup.* = .{ .server = server };
        var filled: usize = 0;
        var result = Profile{
            .sample_hz = 0,
            .samples = 0,
            .samples_lost = 0,
            .windows_rejected = windows_rejected,
            .stacks = &.{},
        };
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

    /// Copies the windows that overlap the query into `arena`, oldest first, and says how many
    /// the target lost. Holds the lock.
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

    /// Stops the builder (a build in progress finishes first) and frees everything. What is
    /// still queued is dropped.
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
            // Received, but the server stopped before their table was built.
            .builds_dropped = server.builds.count,
        });
        server.builds.deinit(gpa);
        server.store.deinit(gpa);
        server.binaries.deinit(gpa);
        server.* = undefined;
    }
};

fn window_overlaps(window: *const Message, query: Query) bool {
    const end_unix_ns = window.start_unix_ns +| window.duration_ns;
    return window.start_unix_ns < query.to_unix_ns and end_unix_ns > query.from_unix_ns;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const elf = @import("shared").elf;

test "an empty server starts and stops" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{});
    server.deinit(testing.allocator);
}

test "a server keeps what a registered target ingests, and refuses the rest" {
    const stacks = [_]Message.Stack{.{
        .samples = 1,
        .user = &.{1},
        .kernel = &.{},
        .complete = true,
    }};
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
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);

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

/// A table with one function, `name` (four letters), at file offset 0x1100 .. 0x1140.
fn table_one(gpa: std.mem.Allocator, name: *const [4]u8) !SymbolTable {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little); // The name is at 1.
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    const segments = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};
    const strtab = "\x00" ++ name ++ "\x00";
    return SymbolTable.init(gpa, .{ .segments = &segments, .symtab = &sym, .strtab = strtab });
}

test "the lookup's cache keeps binaries apart, and outlives the table" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1 });
    defer server.deinit(testing.allocator);
    try server.binary_put(testing.allocator, "aa", try table_one(testing.allocator, "work"));
    try server.binary_put(testing.allocator, "bb", try table_one(testing.allocator, "rest"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lookup = try arena.allocator().create(Lookup);
    lookup.* = .{ .server = &server };

    // The same offset in two binaries is two functions.
    const names = arena.allocator();
    const none: ?[]const u8 = null;
    try testing.expectEqualStrings("work", (try lookup.name(names, "aa", 0x1100)).?);
    try testing.expectEqualStrings("rest", (try lookup.name(names, "bb", 0x1100)).?);
    try testing.expectEqual(none, try lookup.name(names, "aa", 0x9000));
    try testing.expectEqual(none, try lookup.name(names, "cc", 0x1100));

    // Gone from the server, still named from the cache: the build ID says it is the same file.
    server.binaries.deinit(testing.allocator);
    server.binaries = try Binaries.init(testing.allocator, 4, 1 << 20);
    try testing.expectEqualStrings("work", (try lookup.name(names, "aa", 0x1100)).?);
}

fn stack_test(samples: u64, user: []const u64) Message.Stack {
    return .{ .samples = samples, .user = user, .kernel = &.{}, .complete = true };
}

/// A window of 100 ns from `start_unix_ns`, whose samples are those of its stacks.
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

test "a profile names the functions, merges the windows and keeps to the time range" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 4,
        .window_bytes_max = 4096,
    });
    defer server.deinit(testing.allocator);
    const target = try server.target_add(testing.allocator, 1);

    // The file offset 0x1100 is at address 0x7100 in this process.
    try server.binary_put(testing.allocator, "aa", try table_one(testing.allocator, "work"));
    const regions = [_]agent.Region{.{
        .start = 0x7000,
        .end = 0x8000,
        .offset = 0x1000,
        .inode = 1,
        .path = "/bin/app",
        .build_id = "aa",
    }};

    // Two windows; the leaf is in `work` at different instructions, the caller is unknown.
    const first = [_]Message.Stack{stack_test(3, &.{ 0x7110, 0x7220 })};
    const second = [_]Message.Stack{stack_test(4, &.{ 0x7120, 0x7220 })};
    try server.ingest(target, &window_test(100, 1, &regions, &first));
    try server.ingest(target, &window_test(200, 0, &regions, &second));

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

    // Only the second window overlaps 250 .. 1000.
    const late = try server.profile(arena.allocator(), query_test(target, 250, 1000));
    try testing.expectEqual(@as(u64, 4), late.samples);
    try testing.expectEqual(@as(u64, 4), late.stacks[0].samples);

    const none = try server.profile(arena.allocator(), query_test(target, 1000, 2000));
    try testing.expectEqual(@as(usize, 0), none.stacks.len);
    try testing.expectEqual(@as(u64, 0), none.samples);

    // A report the run could not copy shows in the profile as a lost window.
    try testing.expectEqual(@as(u64, 0), all.windows_rejected);
    try server.window_dropped(target);
    const after = try server.profile(arena.allocator(), query_test(target, 0, 1000));
    try testing.expectEqual(@as(u64, 1), after.windows_rejected);

    const unknown = query_test(999, 0, 1000);
    try testing.expectError(error.TargetUnknown, server.profile(arena.allocator(), unknown));
}

/// A whole binary as an upload hands it over: one function, `name`, at file offset 0x1100.
fn received_one(gpa: std.mem.Allocator, id: []const u8, name: *const [4]u8) !Received {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    const strtab = "\x00" ++ name ++ "\x00";

    var starts = std.EnumArray(agent.binary.Section, usize).initFill(0);
    var sizes = std.EnumArray(agent.binary.Section, usize).initFill(0);
    starts.set(.strtab, sym.len);
    sizes.set(.symtab, sym.len);
    sizes.set(.strtab, strtab.len);
    const segments = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};
    return .{
        .id = try gpa.dupe(u8, id),
        .path = try gpa.dupe(u8, "/bin/app"),
        .segments = try gpa.dupe(elf.Segment, &segments),
        .data = try std.mem.concat(gpa, u8, &.{ &sym, strtab }),
        .starts = starts,
        .sizes = sizes,
    };
}

fn name_of(server: *Server, build_id: []const u8, offset: u64) ?[]const u8 {
    server.lock.lock();
    defer server.lock.unlock();
    const table = server.binaries.get(build_id) orelse return null;
    return (table.lookup(offset) orelse return null).name;
}

test "a received binary is known at once, and named once the builder is done" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{ .targets_max = 1 });
    defer server.deinit(testing.allocator);

    try server.binary_received(try received_one(testing.allocator, "aa", "work"));
    // Known while it waits or builds: no other run sends it again.
    try testing.expect(server.binary_known("aa"));
    // A second copy, from another run, is dropped.
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
    // Refused, and remembered: no run sends it again only to be refused again.
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
    server.deinit(testing.allocator); // The testing allocator reports anything left behind.
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

    // An abort gives its bytes back at once; an end only once the table is built.
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
    // A window of "aa" arrives: "bb", put after it, is now the older.
    const regions = [_]agent.Region{.{
        .start = 0x7000,
        .end = 0x8000,
        .offset = 0x1000,
        .inode = 1,
        .path = "/bin/app",
        .build_id = "aa",
    }};
    const stacks = [_]Message.Stack{stack_test(1, &.{0x7110})};
    try server.ingest(target, &window_test(100, 0, &regions, &stacks));

    try server.binary_put(testing.allocator, "cc", try table_one(testing.allocator, "more"));
    try testing.expect(server.binary_known("aa"));
    try testing.expect(!server.binary_known("bb"));
}
