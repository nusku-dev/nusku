const std = @import("std");
const webui = @import("webui");
const client = @import("client");
const json = @import("json.zig");
const session = @import("session.zig");

const poll_ms = 20;
const first_frame_ms = 3000;

pub fn get(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answer = processes_json(&session.current, arena) catch |err| json.from_error(arena, err);
    e.returnString(answer);
}

fn processes_json(s: *client.Session, arena: std.mem.Allocator) ![:0]const u8 {
    var waited_ms: u32 = 0;
    while (waited_ms < first_frame_ms) : (waited_ms += poll_ms) {
        if (try s.processes(arena)) |frame| return json.of(arena, frame);
        sleep_ms(poll_ms);
    }
    return error.NoFrameYet;
}

fn sleep_ms(ms: u32) void {
    const duration = std.os.linux.timespec{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&duration, null);
}

test "an error goes to the UI as its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_resp = json.from_error(arena.allocator(), error.PermissionDenied);
    try std.testing.expectEqualStrings("{\"error\":\"PermissionDenied\"}", json_resp);
}

test "a frame of the protocol becomes JSON the UI reads" {
    const protocol = @import("shared").protocol;
    const infos = [_]protocol.ProcessInfo{.{
        .pid = 7,
        .name = "app",
        .user = "ali",
        .command = "/bin/app",
        .threads = 2,
        .cpu_percent = 12.5,
        .memory_bytes = 4096,
        .started_unix_ns = 1_000_000_000,
    }};
    const frame = protocol.ProcessFrame{
        .unix_ns = 2_000_000_000,
        .interval_ns = 1_000_000_000,
        .processes = &infos,
        .machine = .{ .cpus = 8, .cpu = null },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_resp = try json.of(arena.allocator(), frame);
    try std.testing.expect(std.mem.indexOf(u8, json_resp, "\"cpu_percent\":12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_resp, "\"name\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_resp, "\"cpus\":8,\"cpu\":null") != null);
}

test "processes answers with this machine's processes, through the session" {
    const s = try std.testing.allocator.create(client.Session);
    defer std.testing.allocator.destroy(s);
    try s.init(std.testing.allocator, .{ .profiles_max = 1, .processes_interval_ms = 100 });
    defer s.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json_resp = try processes_json(s, arena.allocator());
    const parsed = try std.json.parseFromSliceLeaky(struct {
        processes: []const struct { pid: u32 },
        machine: struct { cpus: u32 },
    }, arena.allocator(), json_resp, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.processes.len >= 2);
    try std.testing.expect(parsed.machine.cpus >= 1);
    const own: u32 = @intCast(std.os.linux.getpid());
    for (parsed.processes) |info| {
        if (info.pid == own) break;
    } else return error.OwnProcessMissing;
}
