//! The server: it keeps what the agents report, names the addresses with the symbols of their
//! binaries, and answers queries with profiles. The controller is the local backend: each run
//! is the agent on a thread of the server's own process.

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

test {
    _ = @import("os/lock.zig");

    _ = @import("store/store.zig");
    _ = @import("store/window_ring.zig");
    _ = @import("store/binaries.zig");
    _ = @import("store/id_set.zig");

    _ = @import("symbolize/regions.zig");
    _ = @import("symbolize/normalize.zig");
    _ = @import("symbolize/resolve.zig");
    _ = @import("symbolize/merge.zig");
    _ = @import("symbolize/symbol_table.zig");
    _ = @import("symbolize/upload.zig");
    _ = @import("symbolize/builder.zig");

    _ = query_file;
    _ = server_file;
    _ = @import("control/run.zig");
    _ = controller_file;

    // Test-only code lives under testing/: end-to-end tests and their helpers.
    _ = @import("testing/e2e/profile_named.zig");
}
