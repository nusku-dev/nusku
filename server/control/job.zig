//! One job of the controller on a thread of its own.

const std = @import("std");
const agent = @import("agent");
const protocol = @import("shared").protocol;
const server_layer = @import("../server/server.zig");

const Server = server_layer.Server;
const Feed = server_layer.Feed;
const ProbeFeed = server_layer.ProbeFeed;

pub const JobId = u64;

pub const Done = union(enum) {
    profile: protocol.RunStop,
    processes: protocol.WatchStop,
    probe: protocol.RunStop,
};

pub const Job = struct {
    id: JobId,
    active: bool,
    thread: std.Thread,
    work: union(enum) {
        profile: struct { run: agent.Run, feed: Feed },
        processes: agent.Watch,
        probe: struct { run: agent.ProbeRun, feed: ProbeFeed },
    },
    result: anyerror!Done,
    finished: std.atomic.Value(bool),

    pub fn thread_main(job: *Job, server: *Server) void {
        job.result = switch (job.work) {
            .profile => |*profile| profile_take(&profile.run, &profile.feed),
            .processes => |*watch| processes_take(watch, server),
            .probe => |*probe| probe_take(&probe.run, &probe.feed),
        };
        job.finished.store(true, .release);
    }

    /// Safe from any thread, and from a signal handler.
    pub fn stop(job: *const Job) void {
        switch (job.work) {
            .profile => |*profile| profile.run.stop(),
            .processes => |*watch| watch.stop(),
            .probe => |*probe| probe.run.stop(),
        }
    }

    pub fn deinit(job: *Job) void {
        switch (job.work) {
            .profile => |*profile| {
                profile.feed.close();
                profile.run.deinit();
            },
            .processes => |*watch| watch.deinit(),
            .probe => |*probe| {
                probe.feed.close();
                probe.run.deinit();
            },
        }
        job.active = false;
    }
};

fn probe_take(run: *agent.ProbeRun, feed: *ProbeFeed) !Done {
    while (try run.next()) |event| {
        try feed.take(event);
        if (event == .stopped) return .{ .probe = event.stopped };
    }
    unreachable;
}

fn profile_take(run: *agent.Run, feed: *Feed) !Done {
    while (try run.next()) |event| {
        switch (try feed.take(event)) {
            .none => {},
            .wanted => run.binary_want(true),
            .unwanted => run.binary_want(false),
            .later => run.binary_later(),
            .resend => run.binaries_resend(),
        }
        if (event == .stopped) return .{ .profile = event.stopped };
    }
    unreachable;
}

fn processes_take(watch: *agent.Watch, server: *Server) !Done {
    while (try watch.next()) |event| {
        try server.watch_take(event);
        if (event == .stopped) return .{ .processes = event.stopped };
    }
    unreachable;
}
