//! The newest frame of the processes watch, copied into memory the server owns.

const std = @import("std");
const procs = @import("agent").processes;
const Frame = procs.Frame;
const ProcessInfo = procs.ProcessInfo;

pub const LatestFrame = struct {
    /// Received since the server started.
    frames: u64 = 0,
    /// Null before the first. Points into `arena`.
    frame: ?Frame = null,
    /// Reset for each frame, keeping its memory.
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) LatestFrame {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(latest: *LatestFrame) void {
        latest.arena.deinit();
        latest.* = undefined;
    }

    /// Keeps a copy of `frame` in place of the last one: the agent reuses its memory.
    pub fn put(latest: *LatestFrame, frame: *const Frame) !void {
        latest.frame = null;
        _ = latest.arena.reset(.retain_capacity);
        latest.frame = try frame_copy(latest.arena.allocator(), frame);
        latest.frames += 1;
    }

    /// A copy in `arena`, which the next `put` cannot change.
    pub fn get(latest: *const LatestFrame, arena: std.mem.Allocator) !?Frame {
        const frame = latest.frame orelse return null;
        return try frame_copy(arena, &frame);
    }
};

/// A deep copy into `arena`.
fn frame_copy(arena: std.mem.Allocator, frame: *const Frame) !Frame {
    const processes = try arena.alloc(ProcessInfo, frame.processes.len);
    for (processes, frame.processes) |*copy, info| copy.* = try info_copy(arena, info);
    var copy = frame.*;
    copy.processes = processes;
    return copy;
}

/// The whole value, then its slices: a new number field is copied without a line here.
fn info_copy(arena: std.mem.Allocator, info: ProcessInfo) !ProcessInfo {
    var copy = info;
    copy.name = try arena.dupe(u8, info.name);
    copy.user = try arena.dupe(u8, info.user);
    copy.command = try arena.dupe(u8, info.command);
    return copy;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn info_test(pid: u32, name: []const u8) ProcessInfo {
    return .{
        .pid = pid,
        .name = name,
        .user = "ali",
        .cpu_percent = 12.5,
        .memory_bytes = 4096,
        .started_unix_ns = 1000,
        .command = "/bin/app --flag",
        .threads = 3,
    };
}

test "nothing is kept before the first frame" {
    var latest = LatestFrame.init(testing.allocator);
    defer latest.deinit();
    try testing.expectEqual(@as(?Frame, null), try latest.get(testing.allocator));
}

test "a kept frame is a copy: it outlives the frame it came from" {
    var latest = LatestFrame.init(testing.allocator);
    defer latest.deinit();

    var name_buffer = "worker".*;
    const infos = [_]ProcessInfo{ info_test(10, &name_buffer), info_test(20, "db") };
    try latest.put(&.{ .unix_ns = 5, .interval_ns = 7, .processes = &infos });
    name_buffer = "XXXXXX".*; // As the agent reuses its memory.

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frame = (try latest.get(arena.allocator())).?;
    try testing.expectEqual(@as(u64, 5), frame.unix_ns);
    try testing.expectEqual(@as(u64, 7), frame.interval_ns);
    try testing.expectEqual(@as(usize, 2), frame.processes.len);

    const first = frame.processes[0];
    try testing.expectEqualStrings("worker", first.name);
    try testing.expectEqualStrings("ali", first.user);
    try testing.expectEqualStrings("/bin/app --flag", first.command);
    try testing.expectEqual(@as(?f32, 12.5), first.cpu_percent);
    try testing.expectEqual(@as(u32, 3), first.threads);
}

test "a new frame takes the place of the one before" {
    var latest = LatestFrame.init(testing.allocator);
    defer latest.deinit();

    const one = [_]ProcessInfo{info_test(1, "first")};
    const two = [_]ProcessInfo{ info_test(2, "second"), info_test(3, "third") };
    try latest.put(&.{ .unix_ns = 1, .interval_ns = 0, .processes = &one });
    try latest.put(&.{ .unix_ns = 2, .interval_ns = 9, .processes = &two });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const frame = (try latest.get(arena.allocator())).?;
    try testing.expectEqual(@as(u64, 2), frame.unix_ns);
    try testing.expectEqualStrings("second", frame.processes[0].name);
    try testing.expectEqual(@as(u64, 2), latest.frames);
}

test "what get gives is the caller's: the next put does not change it" {
    var latest = LatestFrame.init(testing.allocator);
    defer latest.deinit();

    const one = [_]ProcessInfo{info_test(1, "first")};
    try latest.put(&.{ .unix_ns = 1, .interval_ns = 0, .processes = &one });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const read = (try latest.get(arena.allocator())).?;

    const two = [_]ProcessInfo{info_test(2, "other")};
    try latest.put(&.{ .unix_ns = 2, .interval_ns = 0, .processes = &two });
    try testing.expectEqualStrings("first", read.processes[0].name);
}
