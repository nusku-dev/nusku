//! The client layer: how a command reaches a server. Today one way, local: the server and the
//! agent in this process, the agent on threads of its own. A remote client would go next to it,
//! as client/remote.zig with the same three functions, and this file would pick one.
//!
//!     const result = try client.profile(gpa, arena, .{ .pid = pid, ... }, live);
//!     const frame = try client.processes(gpa, arena, interval_ms);
//!     try client.processes_watch(gpa, interval_ms, live);
//!
//! Ctrl-C stops what runs, not the program: the result still comes back.

const local = @import("local.zig");

pub const ProfileOptions = local.Options;
/// Shown the profile so far, while it runs.
pub const Live = local.Live;
pub const Result = local.Result;
/// Shown each new frame of the processes watch.
pub const ProcessesLive = local.ProcessesLive;

/// The profile of a whole run.
pub const profile = local.profile;
/// The processes of this machine once, with their CPU.
pub const processes = local.processes;
/// A frame of the processes every interval, until Ctrl-C.
pub const processes_watch = local.processes_watch;

test {
    _ = local;
}
