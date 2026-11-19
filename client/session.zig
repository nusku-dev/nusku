//! One long-lived server: many profiles at once and the processes watch.

const std = @import("std");
const server_lib = @import("server");
const protocol = @import("shared").protocol;
const local = @import("local.zig");
const profile_cache = @import("profile_cache.zig");

const assert = std.debug.assert;
const Server = server_lib.Server;
const Controller = server_lib.Controller;
const JobId = server_lib.JobId;
const TargetId = server_lib.TargetId;
const ProfileCache = profile_cache.ProfileCache;
pub const Delta = profile_cache.Delta;

pub const Options = struct {
    profiles_max: u32 = 8,
    windows_per_profile: u32 = 600,
    processes_interval_ms: u32 = 1000,
};

pub const UserId = u64;

pub const Started = struct {
    job: JobId,
    pid: u32,
    joined: bool,
};

pub const Stopped = struct {
    reason: ?protocol.RunStop,
    users: u32,
};

pub const ProfileState = struct {
    job: JobId,
    pid: u32,
    running: bool,
    users: u32,
    elapsed_ms: u64,
    reason: ?protocol.RunStop,
    failure: ?[]const u8,
    profile: ?server_lib.Profile,
};

const users_max = 8;

const Entry = struct {
    job: JobId,
    target: TargetId,
    pid: u32,
    started_ms: u64,
    ended_ms: ?u64 = null,
    reason: ?protocol.RunStop = null,
    failure: ?anyerror = null,
    users: [users_max]UserId = undefined,
    users_count: u32 = 0,
    cache: ?*ProfileCache = null,

    fn open(entry: *const Entry) bool {
        return entry.ended_ms == null;
    }

    fn user_index(entry: *const Entry, user: UserId) ?usize {
        for (entry.users[0..entry.users_count], 0..) |known, index| {
            if (known == user) return index;
        }
        return null;
    }

    fn user_add(entry: *Entry, user: UserId) !void {
        if (entry.user_index(user) != null) return;
        if (entry.users_count == users_max) return error.UsersFull;
        entry.users[entry.users_count] = user;
        entry.users_count += 1;
    }

    fn user_remove(entry: *Entry, user: UserId) !void {
        const index = entry.user_index(user) orelse return error.NotJoined;
        entry.users_count -= 1;
        entry.users[index] = entry.users[entry.users_count];
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    lock: std.c.pthread_mutex_t,
    server: Server,
    controller: Controller,
    entries: []Entry,
    count: u32,
    watch_job: ?JobId,
    processes_interval_ms: u32,

    /// The session must stay at its address until `deinit`.
    pub fn init(session: *Session, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.profiles_max > 0);
        assert(options.processes_interval_ms > 0);
        const entries = try gpa.alloc(Entry, options.profiles_max);
        errdefer gpa.free(entries);
        try session.server.init(gpa, .{ .windows = .{
            .targets_max = options.profiles_max,
            .windows_per_target_max = options.windows_per_profile,
        } });
        errdefer session.server.deinit();
        try session.controller.init(gpa, &session.server, .{
            .jobs_max = options.profiles_max + 1,
        });
        session.gpa = gpa;
        session.lock = std.c.PTHREAD_MUTEX_INITIALIZER;
        session.entries = entries;
        session.count = 0;
        session.watch_job = null;
        session.processes_interval_ms = options.processes_interval_ms;
    }

    pub fn deinit(session: *Session) void {
        for (session.entries[0..session.count]) |*entry| {
            if (entry.cache) |cache| cache.deinit(session.gpa);
        }
        session.controller.deinit();
        session.server.deinit();
        session.gpa.free(session.entries);
        session.* = undefined;
    }

    /// Joins the running profile of the same pid instead of starting another.
    pub fn profile_start(session: *Session, options: local.Options, user: UserId) !Started {
        session.held();
        defer session.release();
        session.reap();

        for (session.entries[0..session.count]) |*entry| {
            const pid = options.pid orelse break;
            if (entry.pid != pid or !entry.open()) continue;
            try entry.user_add(user);
            return .{ .job = entry.job, .pid = pid, .joined = true };
        }
        if (session.count == session.entries.len) try session.drop_oldest_ended();

        const started = try session.controller.start(.{ .profile = .{
            .pid = options.pid,
            .program = options.program,
            .metrics = options.metrics,
            .interval_ms = options.interval_ms,
            .duration_s = options.duration_s,
        } });
        const entry = &session.entries[session.count];
        entry.* = .{
            .job = started.job,
            .target = started.target.?,
            .pid = started.pid.?,
            .started_ms = local.monotonic_ms(),
        };
        entry.user_add(user) catch unreachable;
        session.count += 1;
        return .{ .job = started.job, .pid = entry.pid, .joined = false };
    }

    /// Only the profiling ends, never the process; it ends once no user is left.
    pub fn profile_stop(session: *Session, job: JobId, user: UserId) !Stopped {
        session.held();
        defer session.release();
        const entry = session.find(job) orelse return error.ProfileUnknown;
        if (entry.open()) {
            try entry.user_remove(user);
            if (entry.users_count > 0) return .{ .reason = null, .users = entry.users_count };
            entry_end(entry, session.controller.stop(job));
        }
        if (entry.failure) |err| return err;
        return .{ .reason = entry.reason.?, .users = 0 };
    }

    /// Drops the user from every profile; one left without users stops.
    pub fn user_leave(session: *Session, user: UserId) void {
        session.held();
        defer session.release();
        for (session.entries[0..session.count]) |*entry| {
            if (!entry.open()) continue;
            entry.user_remove(user) catch continue;
            if (entry.users_count == 0) entry_end(entry, session.controller.stop(entry.job));
        }
    }

    pub fn profiles(session: *Session, arena: std.mem.Allocator) ![]ProfileState {
        session.held();
        session.reap();
        const entries = arena.dupe(Entry, session.entries[0..session.count]) catch |err| {
            session.release();
            return err;
        };
        session.release();

        const now_ms = local.monotonic_ms();
        const states = try arena.alloc(ProfileState, entries.len);
        for (entries, states) |*entry, *state| {
            const query = server_lib.Query{ .target = entry.target, .stacks = false };
            state.* = .{
                .job = entry.job,
                .pid = entry.pid,
                .running = entry.open(),
                .users = entry.users_count,
                .elapsed_ms = (entry.ended_ms orelse now_ms) - entry.started_ms,
                .reason = entry.reason,
                .failure = if (entry.failure) |err| @errorName(err) else null,
                .profile = session.server.profile(arena, query, .as_they_are) catch null,
            };
        }
        return states;
    }

    pub fn profile_range(
        session: *Session,
        arena: std.mem.Allocator,
        job: JobId,
        from_unix_ns: u64,
        to_unix_ns: u64,
    ) !server_lib.Profile {
        assert(from_unix_ns < to_unix_ns);
        const found = try session.target_of(job);
        const query = server_lib.Query{
            .target = found.target,
            .from_unix_ns = from_unix_ns,
            .to_unix_ns = to_unix_ns,
        };
        return session.server.profile(arena, query, found.names);
    }

    pub fn processes(session: *Session, arena: std.mem.Allocator) !?protocol.ProcessFrame {
        try session.watch_ensure();
        return (try session.server.processes(arena)).frame;
    }

    fn watch_ensure(session: *Session) !void {
        session.held();
        defer session.release();
        if (session.watch_job) |job| {
            if (session.controller.running(job)) return;
            _ = session.controller.wait(job) catch {};
            session.watch_job = null;
        }
        const started = try session.controller.start(.{ .processes = .{
            .interval_ms = session.processes_interval_ms,
        } });
        session.watch_job = started.job;
    }

    fn reap(session: *Session) void {
        for (session.entries[0..session.count]) |*entry| {
            if (!entry.open() or session.controller.running(entry.job)) continue;
            entry_end(entry, session.controller.wait(entry.job));
        }
    }

    fn entry_end(entry: *Entry, done: anyerror!server_lib.Done) void {
        entry.ended_ms = local.monotonic_ms();
        entry.users_count = 0;
        if (done) |result| {
            entry.reason = result.profile;
        } else |err| {
            entry.failure = err;
        }
    }

    fn drop_oldest_ended(session: *Session) !void {
        const entries = session.entries[0..session.count];
        var oldest: ?usize = null;
        for (entries, 0..) |*entry, index| {
            if (entry.open()) continue;
            if (oldest == null or entry.job < entries[oldest.?].job) oldest = index;
        }
        const index = oldest orelse return error.ProfilesFull;
        if (entries[index].cache) |cache| {
            if (cache.users == 0) cache.deinit(session.gpa) else cache.orphaned = true;
        }
        std.mem.copyForwards(Entry, entries[index..], entries[index + 1 ..]);
        session.count -= 1;
    }

    fn find(session: *Session, job: JobId) ?*Entry {
        for (session.entries[0..session.count]) |*entry| {
            if (entry.job == job) return entry;
        }
        return null;
    }

    fn held(session: *Session) void {
        const result = std.c.pthread_mutex_lock(&session.lock);
        assert(result == .SUCCESS);
    }

    fn release(session: *Session) void {
        const result = std.c.pthread_mutex_unlock(&session.lock);
        assert(result == .SUCCESS);
    }

    /// What changed since the clock `since` (0 for all of it), or null for nothing.
    pub fn profile_get(
        session: *Session,
        arena: std.mem.Allocator,
        job: JobId,
        since: u64,
    ) !?Delta {
        const found = try session.target_of(job);
        const counts = server_lib.Query{ .target = found.target, .stacks = false };
        const summary = try session.server.profile(arena, counts, found.names);
        const version = version_of(&summary, found.names);

        const cache = try session.cache_take(job);
        defer session.cache_give(cache);
        if (cache.unchanged(version, since)) return null;
        const server = &session.server;
        return try cache.update(session.gpa, arena, server, found.target, found.names, &summary, version, since);
    }

    fn cache_take(session: *Session, job: JobId) !*ProfileCache {
        session.held();
        defer session.release();
        const entry = session.find(job) orelse return error.ProfileUnknown;
        const cache = entry.cache orelse try ProfileCache.create(session.gpa);
        entry.cache = cache;
        cache.users += 1;
        return cache;
    }

    fn cache_give(session: *Session, cache: *ProfileCache) void {
        session.held();
        defer session.release();
        cache.users -= 1;
        if (cache.orphaned and cache.users == 0) cache.deinit(session.gpa);
    }

    const Found = struct { target: TargetId, names: server_lib.Names };

    fn target_of(session: *Session, job: JobId) !Found {
        session.held();
        defer session.release();
        session.reap();
        const entry = session.find(job) orelse return error.ProfileUnknown;
        const names: server_lib.Names = if (entry.open()) .as_they_are else .all_built;
        return .{ .target = entry.target, .names = names };
    }
};

const testing = std.testing;
const cpu = std.EnumSet(protocol.Metric).initOne(.cpu);

fn version_of(profile: *const server_lib.Profile, names: server_lib.Names) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const last: u64 = if (profile.windows.len > 0)
        profile.windows[profile.windows.len - 1].start_unix_ns
    else
        0;
    const parts = [_]u64{
        profile.windows.len,
        last,
        profile.samples,
        profile.samples_lost,
        profile.names_generation,
        @intFromEnum(names),
    };
    hasher.update(std.mem.sliceAsBytes(&parts));
    return (hasher.final() & ((1 << 53) - 1)) | 1;
}

fn session_test() !*Session {
    const session = try testing.allocator.create(Session);
    errdefer testing.allocator.destroy(session);
    try session.init(testing.allocator, .{
        .profiles_max = 2,
        .windows_per_profile = 16,
        .processes_interval_ms = 100,
    });
    return session;
}

fn session_destroy(session: *Session) void {
    session.deinit();
    testing.allocator.destroy(session);
}

test "an unknown profile and a bad pid are refused" {
    const session = try session_test();
    defer session_destroy(session);
    try testing.expectError(error.ProfileUnknown, session.profile_stop(42, 1));
    const bad = local.Options{ .pid = 0, .metrics = cpu, .interval_ms = 100, .duration_s = 0 };
    try testing.expectError(error.InvalidPid, session.profile_start(bad, 1));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try session.profiles(arena.allocator())).len);
}

test "the processes watch runs once and gives frames" {
    const session = try session_test();
    defer session_destroy(session);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var waited: u32 = 0;
    while (try session.processes(arena.allocator()) == null) : (waited += 1) {
        if (waited > 100) return error.NoFrame;
        local.sleep_ms(20);
    }
    const frame = (try session.processes(arena.allocator())).?;
    try testing.expect(frame.processes.len >= 2);
    try testing.expect(session.watch_job != null);
}

test "two processes profiled at once, each stopped on its own (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const session = try session_test();
    defer session_destroy(session);
    const own: u32 = @intCast(std.os.linux.getpid());
    const base = local.Options{ .pid = own, .metrics = cpu, .interval_ms = 100, .duration_s = 0 };

    const first = try session.profile_start(base, 1);
    try testing.expect(!first.joined);
    var init_options = base;
    init_options.pid = 1;
    const second = try session.profile_start(init_options, 1);
    var other = base;
    other.pid = 2;
    try testing.expectError(error.ProfilesFull, session.profile_start(other, 1));

    burn_ms(500);
    const stopped = try session.profile_stop(first.job, 1);
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), stopped.reason);
    const again = try session.profile_stop(first.job, 1);
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), again.reason);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const states = try session.profiles(arena.allocator());
    try testing.expectEqual(@as(usize, 2), states.len);
    try testing.expectEqual(first.job, states[0].job);
    try testing.expect(!states[0].running);
    try testing.expect(states[0].profile.?.samples > 0);
    try testing.expectEqual(@as(usize, 0), states[0].profile.?.stacks.len);
    const whole = (try session.profile_get(arena.allocator(), first.job, 0)).?;
    try testing.expect(whole.full);
    try testing.expect(whole.profile.stacks.len > 0);
    try testing.expectEqual(states[0].profile.?.samples, whole.profile.samples);
    const unchanged = try session.profile_get(arena.allocator(), first.job, whole.clock);
    try testing.expect(unchanged == null);
    const windows = states[0].profile.?.windows;
    try testing.expect(windows.len > 0);
    const last = windows[windows.len - 1];
    const tail = try session.profile_range(
        arena.allocator(),
        first.job,
        last.start_unix_ns + last.duration_ns / 2,
        last.start_unix_ns + last.duration_ns / 2 + 1,
    );
    try testing.expectEqual(@as(usize, 1), tail.windows.len);
    try testing.expectEqual(last.samples, tail.samples);
    try testing.expectEqual(second.job, states[1].job);
    try testing.expect(states[1].running);

    const third = try session.profile_start(base, 1);
    try testing.expect(third.job > second.job);
}

test "a second user joins the same profile, which runs until both stop (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const session = try session_test();
    defer session_destroy(session);
    const own: u32 = @intCast(std.os.linux.getpid());
    const base = local.Options{ .pid = own, .metrics = cpu, .interval_ms = 100, .duration_s = 0 };

    const first = try session.profile_start(base, 1);
    const joined = try session.profile_start(base, 2);
    try testing.expect(joined.joined);
    try testing.expectEqual(first.job, joined.job);
    const twice = try session.profile_start(base, 2);
    try testing.expectEqual(first.job, twice.job);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const states = try session.profiles(arena.allocator());
    try testing.expectEqual(@as(usize, 1), states.len);
    try testing.expectEqual(@as(u32, 2), states[0].users);

    burn_ms(300);
    try testing.expectError(error.NotJoined, session.profile_stop(first.job, 3));
    const left = try session.profile_stop(first.job, 1);
    try testing.expectEqual(@as(?protocol.RunStop, null), left.reason);
    try testing.expectEqual(@as(u32, 1), left.users);
    try testing.expect(session.controller.running(first.job));

    const last = try session.profile_stop(first.job, 2);
    try testing.expectEqual(@as(?protocol.RunStop, .cancelled), last.reason);
    try testing.expect(!session.controller.running(first.job));
}

test "a user that leaves gives up its share of every profile (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const session = try session_test();
    defer session_destroy(session);
    const own: u32 = @intCast(std.os.linux.getpid());
    const base = local.Options{ .pid = own, .metrics = cpu, .interval_ms = 100, .duration_s = 0 };
    var init_options = base;
    init_options.pid = 1;

    const shared = try session.profile_start(base, 1);
    _ = try session.profile_start(base, 2);
    const alone = try session.profile_start(init_options, 2);

    session.user_leave(2);
    try testing.expect(session.controller.running(shared.job));
    try testing.expect(!session.controller.running(alone.job));
    session.user_leave(2);

    session.user_leave(1);
    try testing.expect(!session.controller.running(shared.job));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (try session.profiles(arena.allocator())) |state| {
        try testing.expect(!state.running);
        try testing.expectEqual(@as(?protocol.RunStop, .cancelled), state.reason);
    }
}

test "a live profile kept one report at a time equals one built whole (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const session = try testing.allocator.create(Session);
    defer testing.allocator.destroy(session);
    try session.init(testing.allocator, .{ .profiles_max = 1, .windows_per_profile = 4 });
    defer session.deinit();
    const own: u32 = @intCast(std.os.linux.getpid());
    const options = local.Options{
        .pid = own,
        .metrics = cpu,
        .interval_ms = 100,
        .duration_s = 0,
    };
    const started = try session.profile_start(options, 1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var held = std.AutoHashMap(u32, server_lib.SymbolStack).init(testing.allocator);
    defer held.deinit();
    var clock: u64 = 0;
    var answers: u32 = 0;
    var partial: u32 = 0;
    for (0..12) |_| {
        burn_ms(150);
        _ = arena.reset(.retain_capacity);
        const asked = try session.profile_get(arena.allocator(), started.job, clock);
        const got = asked orelse continue;
        try delta_apply(&held, got);
        clock = got.clock;
        answers += 1;
        partial += @intFromBool(!got.full);
    }
    try testing.expect(answers >= 6);
    try testing.expect(partial >= 4);
    _ = try session.profile_stop(started.job, 1);

    _ = arena.reset(.retain_capacity);
    const last = (try session.profile_get(arena.allocator(), started.job, clock)).?;
    try delta_apply(&held, last);
    var kept_list: std.ArrayList(server_lib.SymbolStack) = .empty;
    defer kept_list.deinit(testing.allocator);
    var values = held.valueIterator();
    while (values.next()) |stack| try kept_list.append(testing.allocator, stack.*);
    const kept = server_lib.Profile{
        .sample_hz = last.profile.sample_hz,
        .samples = last.profile.samples,
        .samples_lost = 0,
        .windows_rejected = 0,
        .stacks = kept_list.items,
    };
    const found = try session.target_of(started.job);
    const query = server_lib.Query{ .target = found.target };
    const whole = try session.server.profile(arena.allocator(), query, found.names);
    try testing.expect(whole.windows.len <= 4);
    try testing.expectEqual(whole.samples, kept.samples);
    try testing.expectEqual(whole.stacks.len, kept.stacks.len);
    var sum: u64 = 0;
    for (kept.stacks) |stack| sum += stack.samples;
    try testing.expectEqual(whole.samples, sum);
    for (whole.stacks) |stack| {
        const match = for (kept.stacks) |other| {
            if (stack_same(stack, other)) break other;
        } else return error.StackMissing;
        try testing.expectEqual(stack.samples, match.samples);
    }
}

test "a launched program is profiled from its start, and ended with it or not (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const session = try session_test();
    defer session_destroy(session);
    const busy = [_][]const u8{ "sh", "-c", "while :; do :; done" };
    var options = local.Options{ .metrics = cpu, .interval_ms = 100, .duration_s = 1 };
    options.program = .{ .argv = &busy };
    const ended = try session.profile_start(options, 1);
    options.program = .{ .argv = &busy, .keep_running = true };
    const kept = try session.profile_start(options, 1);
    try testing.expect(!kept.joined);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var waited: u32 = 0;
    var states = try session.profiles(arena.allocator());
    while (states[0].running or states[1].running) : (waited += 1) {
        if (waited > 100) return error.NotEnded;
        local.sleep_ms(50);
        _ = arena.reset(.retain_capacity);
        states = try session.profiles(arena.allocator());
    }
    for (states) |state| {
        try testing.expectEqual(@as(?protocol.RunStop, .duration), state.reason);
        try testing.expect(state.profile.?.samples > 0);
    }
    const ended_pid = states[0].pid;
    const kept_pid = states[1].pid;
    try testing.expectEqual(ended.job, states[0].job);
    try testing.expectEqual(kept.job, states[1].job);
    try testing.expectEqual(ended.pid, ended_pid);
    try testing.expectEqual(kept.pid, kept_pid);

    waited = 0;
    while (alive(ended_pid)) : (waited += 1) {
        if (waited > 100) return error.NotEnded;
        local.sleep_ms(20);
        _ = arena.reset(.retain_capacity);
        _ = try session.profiles(arena.allocator());
    }
    try testing.expect(alive(kept_pid));
    _ = std.os.linux.kill(@intCast(kept_pid), .KILL);
}

fn alive(pid: u32) bool {
    return std.os.linux.errno(std.os.linux.kill(@intCast(pid), @enumFromInt(0))) == .SUCCESS;
}

fn delta_apply(held: *std.AutoHashMap(u32, server_lib.SymbolStack), delta: Delta) !void {
    if (delta.full) held.clearRetainingCapacity();
    for (delta.ids, delta.profile.stacks) |id, stack| {
        if (stack.samples == 0) {
            _ = held.remove(id);
        } else {
            try held.put(id, stack);
        }
    }
}

fn stack_same(a: server_lib.SymbolStack, b: server_lib.SymbolStack) bool {
    if (a.complete != b.complete or a.frames.len != b.frames.len) return false;
    for (a.frames, b.frames) |x, y| {
        if (x.kernel != y.kernel or x.inlined != y.inlined) return false;
        if (!text_same(x.function, y.function) or !text_same(x.module, y.module)) return false;
        if (!text_same(x.file, y.file) or (x.line orelse 0) != (y.line orelse 0)) return false;
        if (x.function == null and x.address != y.address) return false;
    }
    return true;
}

fn text_same(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn burn_ms(ms: u64) void {
    const until_ms = local.monotonic_ms() + ms;
    var spin: u64 = 0;
    while (local.monotonic_ms() < until_ms) spin +%= 1;
    std.mem.doNotOptimizeAway(spin);
}
