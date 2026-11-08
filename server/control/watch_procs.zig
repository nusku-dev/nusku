//! The processes watch: the agent's `processes.watch` on a thread of its own. The thread points
//! into it, so it must not move while the thread lives.

const std = @import("std");
const agent = @import("agent");
const Server = @import("../server.zig").Server;

pub const WatchProcs = struct {
    active: bool,
    server: *Server,
    thread: std.Thread,
    cancel: agent.Cancel,
    options: agent.processes.Options,
    gpa: std.mem.Allocator,
    /// Written by the thread before it ends.
    result: anyerror!agent.processes.StopReason,
    /// Set by the thread as its last act.
    finished: std.atomic.Value(bool),

    pub fn thread_main(watch_procs: *WatchProcs) void {
        watch_procs.result = agent.processes.watch(
            watch_procs.gpa,
            watch_procs.options,
            watch_procs,
            on_frame,
        );
        watch_procs.finished.store(true, .release);
    }

    /// Once per look, on the watch's thread.
    pub fn on_frame(watch_procs: *WatchProcs, frame: *const agent.processes.Frame) !void {
        try watch_procs.server.processes_ingest(frame);
    }
};
