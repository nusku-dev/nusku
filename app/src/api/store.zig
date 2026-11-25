const std = @import("std");
const client = @import("client");
const webui = @import("webui");
const json = @import("json.zig");
const session = @import("session.zig");

const compact = client.compact;
const Store = client.store.StoreRuns;

var store: Store = undefined;
var is_store_init = false;

const Save = struct {
    job: u64,
    label: []const u8,
    note: []const u8 = "",
    program: []const u8 = "",
    command: []const u8 = "",
};

const Relabel = struct {
    id: u64,
    label: []const u8,
    note: []const u8 = "",
};

const Live = *client.Session;
const Arena = std.mem.Allocator;

pub fn init() !void {
    try store.init(std.heap.smp_allocator, null, null);
    is_store_init = true;
}

pub fn deinit() void {
    if (is_store_init) {
        store.deinit(std.heap.smp_allocator);
        is_store_init = false;
        store = undefined;
    }
}

pub fn save(event: webui.Event) void {
    var e = event;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    if (!is_store_init) {
        e.returnString(json.from_error(arena, error.NoRunsDirectory));
        return;
    }
    const input = e.getString();

    const resp = save_json(&store, &session.current, arena, input) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };

    e.returnString(resp);
}

pub fn list(event: webui.Event) void {
    var e = event;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    if (!is_store_init) {
        e.returnString(json.from_error(arena, error.NoRunsDirectory));
        return;
    }

    const resp = list_json(&store, arena) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };

    e.returnString(resp);
}

pub fn get(event: webui.Event) void {
    var e = event;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    if (!is_store_init) {
        e.returnString(json.from_error(arena, error.NoRunsDirectory));
        return;
    }

    const input = e.getInt();

    const resp = get_json(&store, arena, input) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };

    e.returnString(resp);
}

pub fn relabel(event: webui.Event) void {
    var e = event;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    if (!is_store_init) {
        e.returnString(json.from_error(arena, error.NoRunsDirectory));
        return;
    }
    const input = e.getString();

    const resp = relabel_json(&store, arena, input) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };

    e.returnString(resp);
}

pub fn delete(event: webui.Event) void {
    var e = event;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    if (!is_store_init) {
        e.returnString(json.from_error(arena, error.NoRunsDirectory));
        return;
    }

    const input = e.getInt();

    const resp = get_json(&store, arena, input) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };

    e.returnString(resp);
}

fn relabel_json(s: *const Store, arena: Arena, input: []const u8) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Relabel, arena, input, .{}) catch {
        return error.InvalidRequest;
    };
    return json.of(arena, try s.relabel(arena, request.id, request.label, request.note));
}

fn delete_json(s: *const Store, arena: Arena, input: i64) ![:0]const u8 {
    const id = try id_of(input);
    try s.delete(arena, id);
    return json.of(arena, .{ .id = id });
}

fn get_json(s: *const Store, arena: Arena, input: i64) ![:0]const u8 {
    const id = try id_of(input);
    const meta = try json.of(arena, try s.info(arena, id));
    const profile = try s.saved_profile(arena, id);
    const text = "{{\"meta\":{s},\"profile\":{s}}}";
    return std.fmt.allocPrintSentinel(arena, text, .{ meta, profile }, 0);
}

fn save_json(s: *const Store, live: Live, arena: Arena, input: []const u8) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Save, arena, input, .{}) catch {
        return error.InvalidRequest;
    };
    const state = try state_of(live, arena, request.job);
    const profile = try live.profile_whole(arena, request.job);
    const first = if (profile.windows.len > 0) profile.windows[0].start_unix_ns else 0;
    const meta = try s.save(arena, .{
        .label = request.label,
        .note = request.note,
        .program = request.program,
        .command = request.command,
        .pid = state.pid,
        .started_unix_ms = first / std.time.ns_per_ms,
        .elapsed_ms = state.elapsed_ms,
        .samples = profile.samples,
        .sample_hz = profile.sample_hz,
    }, try json.exact(arena, try compact.of(arena, &profile, &.{})));
    return json.of(arena, meta);
}

fn list_json(s: *const Store, arena: Arena) ![:0]const u8 {
    return json.of(arena, try s.list(arena));
}

fn state_of(live: Live, arena: std.mem.Allocator, job: u64) !client.ProfileState {
    for (try live.profiles(arena)) |state| {
        if (state.job == job) return state;
    }
    return error.ProfileUnknown;
}

fn id_of(value: i64) !u64 {
    if (value <= 0) return error.RunUnknown;
    return @intCast(value);
}

const testing = std.testing;

fn store_clear(s: *const Store, arena: Arena) void {
    const metas = s.list(arena) catch &.{};
    for (metas) |meta| s.delete(arena, meta.id) catch {};
    _ = std.os.linux.rmdir(arena.dupeZ(u8, s.dir) catch return);
}

test "runs are saved from a session, listed, read, relabelled and deleted" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const own = std.os.linux.getpid();
    const dir = try std.fmt.allocPrint(a, "/tmp/nusku-app-runs-test-{d}", .{own});
    var s: Store = undefined;
    try s.init(testing.allocator, dir, null);
    defer s.deinit(testing.allocator);
    defer store_clear(&s, a);
    const live = try testing.allocator.create(client.Session);
    defer testing.allocator.destroy(live);
    try live.init(testing.allocator, .{ .profiles_max = 2, .windows_per_profile = 16 });
    defer live.deinit();

    try testing.expectEqualStrings("[]", try list_json(&s, a));
    try testing.expectError(error.InvalidRequest, save_json(&s, live, a, "nope"));
    const unknown = "{\"job\":9,\"label\":\"v1\"}";
    try testing.expectError(error.ProfileUnknown, save_json(&s, live, a, unknown));
    try testing.expectError(error.RunUnknown, get_json(&s, a, 0));
    try testing.expectError(error.RunUnknown, delete_json(&s, a, 7));
    if (std.os.linux.geteuid() != 0) return;

    const started = try live.profile_start(.{
        .pid = @intCast(own),
        .metrics = .initOne(.cpu),
        .interval_ms = 100,
        .duration_s = 0,
    }, 1);
    const pause = std.os.linux.timespec{ .sec = 0, .nsec = 300 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&pause, null);
    const text = "{{\"job\":{d},\"label\":\"own\",\"program\":\"test\"}}";
    const request = try std.fmt.allocPrint(a, text, .{started.job});
    const answer_text = try save_json(&s, live, a, request);
    const saved = try std.json.parseFromSliceLeaky(client.store.Meta, a, answer_text, .{});
    try testing.expectEqualStrings("own", saved.label);
    try testing.expectEqual(@as(u32, @intCast(own)), saved.pid);
    const got = try get_json(&s, a, @intCast(saved.id));
    try testing.expect(std.mem.startsWith(u8, got, "{\"meta\":{"));
    try testing.expect(std.mem.indexOf(u8, got, "\"profile\":{\"sample_hz\":") != null);
    const rename = "{{\"id\":{d},\"label\":\"own, again\"}}";
    const renamed = try std.fmt.allocPrint(a, rename, .{saved.id});
    const relabelled = try relabel_json(&s, a, renamed);
    try testing.expect(std.mem.indexOf(u8, relabelled, "own, again") != null);
    _ = try live.profile_stop(started.job, 1);
}
