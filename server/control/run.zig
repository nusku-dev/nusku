const std = @import("std");
const agent = @import("agent");
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;

// One profiling run. Its address must not change while the thread lives: the thread points
/// into it, so the controller keeps all of them in one array that is never resized.
pub const Run = struct {
    active: bool,
    server: *Server,
    target: TargetId,
    thread: std.Thread,
    cancel: agent.Cancel,
    options: agent.Options,
    /// A report is copied here before it goes to the server: `window_bytes_max` bytes.
    scratch: []align(8) u8,
    /// Reports that did not fit in the scratch buffer. Read after the thread ends.
    windows_dropped: u64,
    /// Written by the thread before it ends: read it after `join`.
    result: anyerror!agent.StopReason,

    pub fn thread_main(run: *Run, gpa: std.mem.Allocator) void {
        run.result = agent.profile(gpa, run.options, run, on_report);
    }

    /// Called by `agent.profile` on the run's thread, once per interval. An error stops the run.
    pub fn on_report(run: *Run, report: *const agent.Report) !void {
        var fixed = std.heap.FixedBufferAllocator.init(run.scratch);
        const message = agent.Message.from_report(fixed.allocator(), report) catch {
            run.windows_dropped += 1;
            return;
        };
        run.server.ingest(run.target, &message) catch |err| switch (err) {
            error.WindowTooLarge => {}, // The store counts it; the run goes on.
            else => return err,
        };
    }
};
