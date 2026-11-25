//! The client: how a program reaches a server.
const server = @import("server");
const local = @import("local.zig");
const session = @import("session.zig");

pub const compact = @import("compact.zig");
pub const store = @import("store_runs.zig");

pub const ProfileOptions = local.Options;
pub const Live = local.Live;
pub const Result = local.Result;
pub const ProcessesLive = local.ProcessesLive;

pub const Session = session.Session;
pub const SessionOptions = session.Options;
pub const ProfileState = session.ProfileState;
pub const UserId = session.UserId;
pub const Started = session.Started;
pub const Stopped = session.Stopped;
pub const Delta = session.Delta;
pub const Profile = server.Profile;
pub const SymbolStack = server.SymbolStack;
pub const Frame = server.Frame;

pub const profile = local.profile;
pub const processes = local.processes;
pub const processes_watch = local.processes_watch;
/// Safe from any thread and from a signal handler.
pub const stop = local.stop;

test {
    _ = store;
    _ = local;
    _ = session;
    _ = compact;
    _ = @import("profile_cache.zig");
}
