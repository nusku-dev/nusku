const std = @import("std");
const webui = @import("webui");
const client = @import("client");

var client_lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

const interval_ms = 1000;

pub fn get(event: webui.Event) void {
    var e = event;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = processes_json(arena) catch |err| error_json(arena, err);
    e.returnString(json);
}

fn processes_json(arena: std.mem.Allocator) ![:0]const u8 {
    _ = std.c.pthread_mutex_lock(&client_lock);
    defer _ = std.c.pthread_mutex_unlock(&client_lock);
    const frame = try client.processes(std.heap.smp_allocator, arena, interval_ms);
    return json_of(arena, frame);
}

fn json_of(arena: std.mem.Allocator, value: anytype) ![:0]const u8 {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    return arena.dupeZ(u8, text);
}

fn error_json(arena: std.mem.Allocator, err: anyerror) [:0]const u8 {
    return json_of(arena, .{ .@"error" = @errorName(err) }) catch "{\"error\":\"OutOfMemory\"}";
}

test "an error goes to the UI as its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = error_json(arena.allocator(), error.PermissionDenied);
    try std.testing.expectEqualStrings("{\"error\":\"PermissionDenied\"}", json);
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
    const json = try json_of(arena.allocator(), frame);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cpu_percent\":12.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cpus\":8,\"cpu\":null") != null);
}

test "processes answers with this machine's processes, through the client the CLI uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try processes_json(arena.allocator());
    const parsed = try std.json.parseFromSliceLeaky(struct {
        processes: []const struct { pid: u32 },
        machine: struct { cpus: u32 },
    }, arena.allocator(), json, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.processes.len >= 2);
    try std.testing.expect(parsed.machine.cpus >= 1);
    const own: u32 = @intCast(std.os.linux.getpid());
    for (parsed.processes) |info| {
        if (info.pid == own) break;
    } else return error.OwnProcessMissing;
}
