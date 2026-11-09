//! One job of the controller on a thread of its own: a profiling run that feeds the server, or
//! the processes watch. The thread points into the job, so it must not move while it runs.

const std = @import("std");
const agent = @import("agent");
const protocol = @import("shared").protocol;
const server_layer = @import("../server/server.zig");

const Server = server_layer.Server;
const Feed = server_layer.Feed;

pub const JobId = u64;

/// Why a job ended: a profile's run, or the watch.
pub const Done = union(enum) {
    profile: protocol.RunStop,
    processes: protocol.WatchStop,
};

pub const Job = struct {
    id: JobId,
    /// The thread runs: `stop` reaches it, and `finish` must join it.
    active: bool,
    thread: std.Thread,
    work: union(enum) {
        profile: struct { run: agent.Run, feed: Feed },
        processes: agent.Watch,
    },
    /// Written by the thread before it ends.
    result: anyerror!Done,
    /// Set by the thread as its last act.
    finished: std.atomic.Value(bool),

    pub fn thread_main(job: *Job, server: *Server) void {
        job.result = switch (job.work) {
            .profile => |*profile| profile_take(&profile.run, &profile.feed),
            .processes => |*watch| processes_take(watch, server),
        };
        job.finished.store(true, .release);
    }

    /// Ends the job at its next wait. Safe from any thread, and from a signal handler.
    pub fn stop(job: *const Job) void {
        switch (job.work) {
            .profile => |*profile| profile.run.stop(),
            .processes => |*watch| watch.stop(),
        }
    }

    /// After the thread is joined.
    pub fn deinit(job: *Job) void {
        switch (job.work) {
            .profile => |*profile| {
                profile.feed.close();
                profile.run.deinit();
            },
            .processes => |*watch| watch.deinit(),
        }
        job.active = false;
    }
};

/// The run's events into the feed, and the feed's answers back to the run.
fn profile_take(run: *agent.Run, feed: *Feed) !Done {
    while (try run.next()) |event| {
        switch (try feed.take(event)) {
            .none => {},
            .wanted => run.binary_want(true),
            .unwanted => run.binary_want(false),
        }
        if (event == .stopped) return .{ .profile = event.stopped };
    }
    unreachable; // `next` gives null only after `.stopped`.
}

fn processes_take(watch: *agent.Watch, server: *Server) !Done {
    while (try watch.next()) |event| {
        try server.watch_take(event);
        if (event == .stopped) return .{ .processes = event.stopped };
    }
    unreachable;
}
