//! The server: keeps what the agents report, names it with their binaries' symbols, and
//! answers with profiles. The controller runs the agent on threads of this process.

const server_file = @import("server.zig");
const controller_file = @import("control/controller.zig");
const query_file = @import("query.zig");

pub const Server = server_file.Server;
pub const TargetId = server_file.TargetId;

pub const Query = query_file.Query;
pub const Profile = query_file.Profile;
pub const SymbolStack = query_file.SymbolStack;
pub const Frame = query_file.Frame;
pub const Stats = query_file.Stats;

pub const Controller = controller_file.Controller;
pub const Spec = controller_file.Spec;

pub const WatchProcsSpec = controller_file.WatchProcsSpec;

/// The agent's, so a caller needs no other module.
pub const Metric = @import("agent").Metric;
pub const StopReason = @import("agent").StopReason;
pub const Cancel = @import("agent").Cancel;
pub const processes = @import("agent").processes;

test {
    _ = @import("os/lock.zig");
    _ = @import("log.zig");

    _ = @import("store/store.zig");
    _ = @import("store/window_ring.zig");
    _ = @import("store/binaries.zig");
    _ = @import("store/id_set.zig");
    _ = @import("store/latest_frame.zig");

    _ = @import("symbolize/regions.zig");
    _ = @import("symbolize/normalize.zig");
    _ = @import("symbolize/resolve.zig");
    _ = @import("symbolize/merge.zig");
    _ = @import("symbolize/lookup.zig");
    _ = @import("symbolize/symbol_table.zig");
    _ = @import("symbolize/upload.zig");
    _ = @import("symbolize/builder.zig");

    _ = query_file;
    _ = server_file;
    _ = @import("control/run.zig");
    _ = @import("control/watch_procs.zig");
    _ = controller_file;

    _ = @import("testing/e2e/profile_named.zig");
}
