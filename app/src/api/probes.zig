const std = @import("std");
const webui = @import("webui");
const client = @import("client");
const protocol = @import("shared").protocol;
const json = @import("json.zig");
const session = @import("session.zig");

const Arena = std.mem.Allocator;
const Live = *client.Session;
const Totals = protocol.probe.Totals;

const Start = struct {
    pid: u32,
    function: []const u8,
    module: ?[]const u8 = null,
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,
};

const Get = struct {
    job: u64,
    from: u64 = 0,
};

const Point = struct {
    t: u64,
    d: u64,
    c: u64,
    n: u64,
    s: u64,
    m: u64,
    h: []const [2]u64,
};

pub fn start(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = start_json(&session.current, arena, e.getString(), e.client_id) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };
    e.returnString(answer);
}

pub fn stop(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = stop_json(&session.current, arena, e.getInt()) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };
    e.returnString(answer);
}

pub fn list(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = list_json(&session.current, arena) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };
    e.returnString(answer);
}

pub fn get(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = get_json(&session.current, arena, e.getString()) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };
    e.returnString(answer);
}

fn start_json(s: Live, arena: Arena, text: []const u8, user: client.UserId) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Start, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    if (request.pid == 0 or request.pid > std.math.maxInt(i32)) return error.InvalidPid;
    if (request.function.len == 0) return error.FunctionNotFound;
    if (request.interval_ms < 10 or request.interval_ms > std.time.ms_per_min) {
        return error.InvalidInterval;
    }
    const job = try s.probe_start(.{
        .pid = request.pid,
        .function = request.function,
        .module = request.module,
        .interval_ms = request.interval_ms,
        .duration_s = request.duration_s,
    }, user);
    return json.of(arena, .{ .job = job });
}

fn stop_json(s: Live, arena: Arena, job: i64) ![:0]const u8 {
    if (job <= 0) return error.ProbeUnknown;
    const reason = try s.probe_stop(@intCast(job));
    return json.of(arena, .{ .job = job, .reason = reason });
}

fn list_json(s: Live, arena: Arena) ![:0]const u8 {
    const states = try s.probe_list(arena);
    const listed = try arena.alloc(Listed, states.len);
    for (states, listed) |state, *out| out.* = .{
        .job = state.job,
        .pid = state.pid,
        .running = state.running,
        .elapsed_ms = state.elapsed_ms,
        .reason = state.reason,
        .failure = state.failure,
        .function = if (state.info) |info| info.function else "",
        .path = if (state.info) |info| info.path else "",
        .calls = state.totals.calls,
        .timed = state.totals.timed,
        .total_ns = state.totals.total_ns,
        .max_ns = state.totals.max_ns,
    };
    return json.exact(arena, listed);
}

const Listed = struct {
    job: u64,
    pid: u32,
    running: bool,
    elapsed_ms: u64,
    reason: ?protocol.RunStop,
    failure: ?[]const u8,
    function: []const u8,
    path: []const u8,
    calls: u64,
    timed: u64,
    total_ns: u64,
    max_ns: u64,
};

fn get_json(s: Live, arena: Arena, text: []const u8) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Get, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    const seen = try s.probe_get(arena, request.job);
    const skip = @min(request.from -| seen.dropped, seen.points.len);
    const points = try arena.alloc(Point, seen.points.len - skip);
    for (seen.points[skip..], points) |report, *out| out.* = try point_of(arena, report);
    return json.exact(arena, .{
        .job = request.job,
        .finished = seen.finished,
        .first = seen.dropped + skip,
        .info = seen.info,
        .unmatched = last_totals(seen.points).unmatched,
        .untimed = last_totals(seen.points).untimed,
        .dropped = last_totals(seen.points).dropped,
        .points = points,
    });
}

fn last_totals(points: []const protocol.probe.Report) Totals {
    return if (points.len > 0) points[points.len - 1].totals else .{};
}

fn point_of(arena: Arena, report: protocol.probe.Report) !Point {
    const totals = report.totals;
    var used: usize = 0;
    for (totals.histogram) |count| used += @intFromBool(count > 0);
    const histogram = try arena.alloc([2]u64, used);
    var filled: usize = 0;
    for (totals.histogram, 0..) |count, bucket| {
        if (count == 0) continue;
        histogram[filled] = .{ bucket, count };
        filled += 1;
    }
    return .{
        .t = report.start_unix_ns / std.time.ns_per_ms,
        .d = report.duration_ns / std.time.ns_per_ms,
        .c = totals.calls,
        .n = totals.timed,
        .s = totals.total_ns,
        .m = totals.max_ns,
        .h = histogram,
    };
}

const testing = std.testing;

test "a probe request is checked before anything starts" {
    const s = try testing.allocator.create(client.Session);
    defer testing.allocator.destroy(s);
    try s.init(testing.allocator, .{ .profiles_max = 2, .windows_per_profile = 16 });
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("[]", try list_json(s, a));
    try testing.expectError(error.InvalidRequest, start_json(s, a, "nope", 1));
    const no_pid = "{\"pid\":0,\"function\":\"f\"}";
    try testing.expectError(error.InvalidPid, start_json(s, a, no_pid, 1));
    const nameless = "{\"pid\":1,\"function\":\"\"}";
    try testing.expectError(error.FunctionNotFound, start_json(s, a, nameless, 1));
    const fast = "{\"pid\":1,\"function\":\"f\",\"interval_ms\":1}";
    try testing.expectError(error.InvalidInterval, start_json(s, a, fast, 1));
    try testing.expectError(error.ProbeUnknown, stop_json(s, a, 9));
    try testing.expectError(error.ProbeUnknown, get_json(s, a, "{\"job\":9}"));
}

test "a point carries its histogram as its buckets that hold calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var totals = Totals{ .calls = 3, .timed = 3, .total_ns = 30, .max_ns = 20 };
    totals.histogram[4] = 2;
    totals.histogram[5] = 1;
    const point = try point_of(arena.allocator(), .{
        .start_unix_ns = 5 * std.time.ns_per_ms,
        .duration_ns = std.time.ns_per_s,
        .totals = totals,
    });
    try testing.expectEqual(@as(u64, 5), point.t);
    try testing.expectEqual(@as(u64, 1000), point.d);
    try testing.expectEqual(@as(usize, 2), point.h.len);
    try testing.expectEqual([2]u64{ 4, 2 }, point.h[0]);
}
