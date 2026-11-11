const std = @import("std");
const webui = @import("webui");
const client = @import("client");
const protocol = @import("shared").protocol;
const json = @import("json.zig");
const session = @import("session.zig");

const Request = struct {
    pid: u32,
    metrics: []const u8 = "cpu",
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,
};

pub fn start(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = e.getString();
    const answer = start_json(&session.current, arena, text, e.client_id) catch |err| {
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

    const job = e.getInt();
    const answer = stop_json(&session.current, arena, job, e.client_id) catch |err| {
        e.returnString(json.from_error(arena, err));
        return;
    };
    e.returnString(answer);
}

pub fn stream(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answer = stream_json(&session.current, arena) catch |err| json.from_error(arena, err);
    e.returnString(answer);
}

pub fn left(event: *webui.Event) void {
    if (event.event_type != .EVENT_DISCONNECTED) return;
    session.current.user_leave(event.client_id);
}

fn start_json(
    s: *client.Session,
    arena: std.mem.Allocator,
    text: []const u8,
    user: client.UserId,
) ![:0]const u8 {
    const options = try options_read(arena, text);
    const started = try s.profile_start(options, user);
    return json.of(arena, .{ .job = started.job, .pid = options.pid, .joined = started.joined });
}

fn stop_json(
    s: *client.Session,
    arena: std.mem.Allocator,
    job: i64,
    user: client.UserId,
) ![:0]const u8 {
    if (job <= 0) return error.ProfileUnknown;
    const stopped = try s.profile_stop(@intCast(job), user);
    return json.of(arena, .{ .job = job, .reason = stopped.reason, .users = stopped.users });
}

fn stream_json(s: *client.Session, arena: std.mem.Allocator) ![:0]const u8 {
    return json.of(arena, try s.profiles(arena));
}

fn options_read(arena: std.mem.Allocator, text: []const u8) !client.ProfileOptions {
    const request = std.json.parseFromSliceLeaky(Request, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    if (request.pid == 0 or request.pid > std.math.maxInt(i32)) return error.InvalidPid;
    if (request.interval_ms < 10 or request.interval_ms > std.time.ms_per_hour) {
        return error.InvalidInterval;
    }
    return .{
        .pid = request.pid,
        .metrics = try metrics_read(request.metrics),
        .interval_ms = request.interval_ms,
        .duration_s = request.duration_s,
    };
}

fn metrics_read(text: []const u8) !std.EnumSet(protocol.Metric) {
    var metrics: std.EnumSet(protocol.Metric) = .initEmpty();
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const metric = std.meta.stringToEnum(protocol.Metric, name) orelse {
            return error.UnknownMetric;
        };
        metrics.insert(metric);
    }
    if (metrics.count() == 0) return error.NoMetrics;
    return metrics;
}

const testing = std.testing;

test "a request becomes profile options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const options = try options_read(arena.allocator(),
        \\{"pid":42,"metrics":"cpu, offcpu","interval_ms":100}
    );
    try testing.expectEqual(@as(u32, 42), options.pid);
    try testing.expectEqual(@as(u32, 100), options.interval_ms);
    try testing.expectEqual(@as(u32, 0), options.duration_s);
    try testing.expect(options.metrics.contains(.cpu));
    try testing.expect(options.metrics.contains(.offcpu));

    const plain = try options_read(arena.allocator(), "{\"pid\":7}");
    try testing.expect(plain.metrics.contains(.cpu));
}

test "a bad request is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidRequest, options_read(a, "nope"));
    try testing.expectError(error.InvalidPid, options_read(a, "{\"pid\":0}"));
    const slow = "{\"pid\":1,\"interval_ms\":5}";
    try testing.expectError(error.InvalidInterval, options_read(a, slow));
    const unknown = "{\"pid\":1,\"metrics\":\"gpu\"}";
    try testing.expectError(error.UnknownMetric, options_read(a, unknown));
    try testing.expectError(error.NoMetrics, options_read(a, "{\"pid\":1,\"metrics\":\" \"}"));
}

test "stream, stop and start answer the UI through one session" {
    const s = try testing.allocator.create(client.Session);
    defer testing.allocator.destroy(s);
    try s.init(testing.allocator, .{ .profiles_max = 2, .windows_per_profile = 16 });
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("[]", try stream_json(s, a));
    try testing.expectError(error.ProfileUnknown, stop_json(s, a, 9, 1));
    try testing.expectError(error.ProfileUnknown, stop_json(s, a, -1, 1));
    if (std.os.linux.geteuid() != 0) return;

    const own = std.os.linux.getpid();
    const request = try std.fmt.allocPrint(a, "{{\"pid\":{d},\"interval_ms\":100}}", .{own});
    const started = try start_json(s, a, request, 1);
    try testing.expect(std.mem.indexOf(u8, started, "\"joined\":false") != null);
    const joined = try start_json(s, a, request, 2);
    try testing.expect(std.mem.indexOf(u8, joined, "\"joined\":true") != null);
    const listed = try stream_json(s, a);
    try testing.expect(std.mem.indexOf(u8, listed, "\"running\":true,\"users\":2") != null);
}
