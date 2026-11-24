//! The function probes of a session: who started each, and how it ended.

const std = @import("std");
const server_lib = @import("server");
const protocol = @import("shared").protocol;

const Controller = server_lib.Controller;
const JobId = server_lib.JobId;

pub const probes_max = 8;

pub const Options = struct {
    pid: u32,
    function: []const u8,
    /// The file to look in, by path or file name; null looks in all of them.
    module: ?[]const u8 = null,
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,
};

pub const Entry = struct {
    job: JobId,
    probe: server_lib.ProbeId,
    pid: u32,
    user: u64,
    started_ms: u64,
    ended_ms: ?u64 = null,
    reason: ?protocol.RunStop = null,
    failure: ?anyerror = null,

    pub fn open(entry: *const Entry) bool {
        return entry.ended_ms == null;
    }

    pub fn end(entry: *Entry, done: anyerror!server_lib.Done, now_ms: u64) void {
        entry.ended_ms = now_ms;
        if (done) |result| {
            entry.reason = result.probe;
        } else |err| {
            entry.failure = err;
        }
    }
};

pub const List = struct {
    entries: [probes_max]Entry = undefined,
    count: u32 = 0,

    /// Room for one more: the oldest ended probe makes it, when the list is full.
    pub fn room(list: *List) !void {
        if (list.count < probes_max) return;
        var oldest: ?usize = null;
        for (list.entries[0..list.count], 0..) |*entry, index| {
            if (entry.open()) continue;
            if (oldest == null or entry.job < list.entries[oldest.?].job) oldest = index;
        }
        const index = oldest orelse return error.ProbesFull;
        const kept = list.entries[0..list.count];
        std.mem.copyForwards(Entry, kept[index..], kept[index + 1 ..]);
        list.count -= 1;
    }

    pub fn add(list: *List, entry: Entry) void {
        std.debug.assert(list.count < probes_max);
        list.entries[list.count] = entry;
        list.count += 1;
    }

    pub fn find(list: *List, job: JobId) ?*Entry {
        for (list.entries[0..list.count]) |*entry| {
            if (entry.job == job) return entry;
        }
        return null;
    }

    /// Ends the probes whose job has finished on its own.
    pub fn reap(list: *List, controller: *Controller, now_ms: u64) void {
        for (list.entries[0..list.count]) |*entry| {
            if (!entry.open() or controller.running(entry.job)) continue;
            entry.end(controller.wait(entry.job), now_ms);
        }
    }

    /// A user that leaves takes its probes with it: nobody is left to look at them.
    pub fn leave(list: *List, controller: *Controller, user: u64, now_ms: u64) void {
        for (list.entries[0..list.count]) |*entry| {
            if (!entry.open() or entry.user != user) continue;
            entry.end(controller.stop(entry.job), now_ms);
        }
    }
};
