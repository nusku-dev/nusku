//! The probes layer: what each function probe reported, one point per interval.

const std = @import("std");
const protocol = @import("shared").protocol;
const os = @import("../os/os.zig");

const assert = std.debug.assert;
const Info = protocol.probe.Info;
const Report = protocol.probe.Report;

pub const ProbeId = u32;

pub const Options = struct {
    probes_max: u32 = 16,
    /// An hour of reports at one a second.
    points_max: u32 = 3600,
};

/// A copy, with its own memory.
pub const Snapshot = struct {
    info: ?Info,
    points: []const Report,
    /// Reports the oldest points made room for.
    dropped: u64,
    finished: bool,
};

const Slot = struct {
    used: bool = false,
    finished: bool = false,
    info: ?Info = null,
    points: std.ArrayList(Report) = .empty,
    dropped: u64 = 0,
    age: u64 = 0,
};

pub const Probes = struct {
    lock: os.Lock,
    slots: []Slot,
    points_max: u32,
    clock: u64,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Probes {
        assert(options.probes_max > 0 and options.points_max > 0);
        const slots = try gpa.alloc(Slot, options.probes_max);
        for (slots) |*slot| slot.* = .{};
        return .{ .lock = .{}, .slots = slots, .points_max = options.points_max, .clock = 0 };
    }

    pub fn deinit(probes: *Probes, gpa: std.mem.Allocator) void {
        for (probes.slots) |*slot| slot_free(gpa, slot);
        gpa.free(probes.slots);
        probes.* = undefined;
    }

    /// A slot for a new probe: a free one, else the oldest finished one.
    pub fn add(probes: *Probes, gpa: std.mem.Allocator) !ProbeId {
        probes.lock.lock();
        defer probes.lock.unlock();
        var pick: ?usize = null;
        for (probes.slots, 0..) |*slot, index| {
            if (!slot.used) {
                pick = index;
                break;
            }
            if (!slot.finished) continue;
            if (pick == null or slot.age < probes.slots[pick.?].age) pick = index;
        }
        const index = pick orelse return error.ProbesFull;
        const slot = &probes.slots[index];
        slot_free(gpa, slot);
        probes.clock += 1;
        slot.* = .{ .used = true, .age = probes.clock };
        return @intCast(index);
    }

    pub fn take(
        probes: *Probes,
        gpa: std.mem.Allocator,
        id: ProbeId,
        event: protocol.ProbeEvent,
    ) !void {
        probes.lock.lock();
        defer probes.lock.unlock();
        const slot = &probes.slots[id];
        assert(slot.used and !slot.finished);
        switch (event) {
            .attached => |info| slot.info = try info_copy(gpa, info.*),
            .report => |report| {
                if (slot.points.items.len == probes.points_max) {
                    _ = slot.points.orderedRemove(0);
                    slot.dropped += 1;
                }
                try slot.points.append(gpa, report.*);
            },
            .stopped => slot.finished = true,
        }
    }

    /// Marks a probe that failed, or ended without saying so, as done.
    pub fn finish(probes: *Probes, id: ProbeId) void {
        probes.lock.lock();
        defer probes.lock.unlock();
        probes.slots[id].finished = true;
    }

    pub fn snapshot(probes: *Probes, arena: std.mem.Allocator, id: ProbeId) !Snapshot {
        probes.lock.lock();
        defer probes.lock.unlock();
        if (id >= probes.slots.len or !probes.slots[id].used) return error.ProbeUnknown;
        const slot = &probes.slots[id];
        return .{
            .info = if (slot.info) |info| try info_copy(arena, info) else null,
            .points = try arena.dupe(Report, slot.points.items),
            .dropped = slot.dropped,
            .finished = slot.finished,
        };
    }
};

fn info_copy(gpa: std.mem.Allocator, info: Info) !Info {
    var copy = info;
    copy.function = try gpa.dupe(u8, info.function);
    errdefer gpa.free(copy.function);
    copy.path = try gpa.dupe(u8, info.path);
    return copy;
}

fn slot_free(gpa: std.mem.Allocator, slot: *Slot) void {
    if (slot.info) |info| {
        gpa.free(info.function);
        gpa.free(info.path);
    }
    slot.points.deinit(gpa);
    slot.* = .{};
}

const testing = std.testing;

fn report_test(calls: u64) Report {
    return .{ .start_unix_ns = calls, .duration_ns = 1, .totals = .{ .calls = calls } };
}

test "a probe keeps its info and its latest points, the oldest dropped first" {
    const gpa = testing.allocator;
    var probes = try Probes.init(gpa, .{ .probes_max = 2, .points_max = 3 });
    defer probes.deinit(gpa);
    const id = try probes.add(gpa);
    const info = Info{ .pid = 7, .function = "work", .path = "/bin/app", .offset = 16, .size = 8 };
    try probes.take(gpa, id, .{ .attached = &info });
    for (1..6) |calls| try probes.take(gpa, id, .{ .report = &report_test(calls) });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const seen = try probes.snapshot(arena.allocator(), id);
    try testing.expectEqualStrings("work", seen.info.?.function);
    try testing.expectEqual(@as(usize, 3), seen.points.len);
    try testing.expectEqual(@as(u64, 3), seen.points[0].totals.calls);
    try testing.expectEqual(@as(u64, 2), seen.dropped);
    try testing.expect(!seen.finished);
    try probes.take(gpa, id, .{ .stopped = .cancelled });
    try testing.expect((try probes.snapshot(arena.allocator(), id)).finished);
}

test "a full store reuses the oldest finished probe, and refuses when all run" {
    const gpa = testing.allocator;
    var probes = try Probes.init(gpa, .{ .probes_max = 2, .points_max = 3 });
    defer probes.deinit(gpa);
    const first = try probes.add(gpa);
    const second = try probes.add(gpa);
    try testing.expectError(error.ProbesFull, probes.add(gpa));
    probes.finish(second);
    probes.finish(first);
    try testing.expectEqual(first, try probes.add(gpa));
    try testing.expectEqual(second, try probes.add(gpa));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expectError(error.ProbeUnknown, probes.snapshot(arena.allocator(), 9));
}
