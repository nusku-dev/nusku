const std = @import("std");
const webui = @import("webui");
const client = @import("client");
const protocol = @import("shared").protocol;
const json = @import("json.zig");
const session = @import("session.zig");
const compact = @import("compact.zig");

const Request = struct {
    pid: u32,
    metrics: []const u8 = "cpu",
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,
};

const Range = struct {
    job: u64,
    from_ms: u64,
    to_ms: u64,
};

const Get = struct {
    job: u64,
    since: u64 = 0,
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

pub fn range(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = e.getString();
    const answer = range_json(&session.current, arena, text) catch |err| json.from_error(arena, err);

    e.returnString(answer);
}

pub fn get(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = e.getString();
    const answer = get_json(&session.current, arena, text) catch |err| json.from_error(arena, err);
    e.returnString(answer);
}

fn get_json(s: *client.Session, arena: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Get, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    const got = try s.profile_get(arena, request.job, request.since) orelse {
        return json.of(arena, .{ .unchanged = true });
    };
    return json.exact(arena, .{
        .clock = got.clock,
        .full = got.full,
        .profile = try compact.of(arena, &got.profile, got.ids),
    });
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
    return json.exact(arena, try s.profiles(arena));
}

fn range_json(s: *client.Session, arena: std.mem.Allocator, text: []const u8) ![:0]const u8 {
    const request = std.json.parseFromSliceLeaky(Range, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    if (request.from_ms >= request.to_ms) return error.InvalidRange;
    const ms = std.time.ns_per_ms;
    const from = std.math.mul(u64, request.from_ms, ms) catch return error.InvalidRange;
    const to = std.math.mul(u64, request.to_ms, ms) catch return error.InvalidRange;
    const profile = try s.profile_range(arena, request.job, from, to);
    return json.exact(arena, try compact.of(arena, &profile, &.{}));
}

fn options_read(arena: std.mem.Allocator, text: []const u8) !client.ProfileOptions {
    const request = std.json.parseFromSliceLeaky(Request, arena, text, .{}) catch {
        return error.InvalidRequest;
    };
    if (request.pid == 0 or request.pid > std.math.maxInt(i32)) return error.InvalidPid;
    return settings_read(request.pid, request.metrics, request.interval_ms, request.duration_s);
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

fn settings_read(pid: u32, metrics: []const u8, interval_ms: u32, duration_s: u32) !client.ProfileOptions {
    if (interval_ms < 10 or interval_ms > std.time.ms_per_hour) return error.InvalidInterval;
    return .{
        .pid = pid,
        .metrics = try metrics_read(metrics),
        .interval_ms = interval_ms,
        .duration_s = duration_s,
    };
}

const testing = std.testing;

fn job_of(answer: []const u8) !u64 {
    const at = (std.mem.indexOf(u8, answer, "\"job\":") orelse return error.NoJob) + 6;
    const end = std.mem.indexOfNonePos(u8, answer, at, "0123456789") orelse answer.len;
    return std.fmt.parseInt(u64, answer[at..end], 10);
}

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
    const empty = "{\"job\":1,\"from_ms\":5,\"to_ms\":5}";
    try testing.expectError(error.InvalidRange, range_json(s, a, empty));
    const unknown = "{\"job\":9,\"from_ms\":1,\"to_ms\":5}";
    try testing.expectError(error.ProfileUnknown, range_json(s, a, unknown));
    try testing.expectError(error.InvalidRequest, range_json(s, a, "nope"));
    try testing.expectError(error.ProfileUnknown, get_json(s, a, "{\"job\":9}"));
    try testing.expectError(error.InvalidRequest, get_json(s, a, "{}"));

    if (std.os.linux.geteuid() != 0) return;

    const own = std.os.linux.getpid();
    const request = try std.fmt.allocPrint(a, "{{\"pid\":{d},\"interval_ms\":100}}", .{own});
    const started = try start_json(s, a, request, 1);
    try testing.expect(std.mem.indexOf(u8, started, "\"joined\":false") != null);
    const joined = try start_json(s, a, request, 2);
    try testing.expect(std.mem.indexOf(u8, joined, "\"joined\":true") != null);
    const listed = try stream_json(s, a);
    try testing.expect(std.mem.indexOf(u8, listed, "\"running\":true,\"users\":2") != null);
    const job_text = try std.fmt.allocPrint(a, "{{\"job\":{d}}}", .{try job_of(started)});
    const whole = try get_json(s, a, job_text);
    try testing.expect(std.mem.indexOf(u8, whole, "\"clock\":") != null);
    try testing.expect(std.mem.indexOf(u8, whole, "\"strings\":") != null);
}
