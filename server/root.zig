//! The server: keeps what the agents report.

const server_file = @import("server/server.zig");
const control_file = @import("control/control.zig");
const naming = @import("naming/naming.zig");

pub const Server = server_file.Server;
pub const Options = server_file.Options;
pub const Feed = server_file.Feed;
pub const TargetId = server_file.TargetId;
pub const Query = server_file.Query;
pub const Names = server_file.Names;
pub const Profile = server_file.Profile;
pub const Latest = server_file.Latest;
pub const SymbolStack = naming.SymbolStack;
pub const Frame = naming.Frame;

pub const Controller = control_file.Controller;
pub const Spec = control_file.Spec;
pub const Started = control_file.Started;
pub const Done = control_file.Done;
pub const JobId = control_file.JobId;

test {
    _ = @import("log.zig");
    _ = @import("os/os.zig");
    _ = @import("windows/windows.zig");
    _ = @import("symbols/symbols.zig");
    _ = @import("processes/processes.zig");
    _ = naming;
    _ = server_file;
    _ = control_file;

    _ = @import("testing/e2e/profile_named.zig");
}
