const server_file = @import("server.zig");
const controller_file = @import("control/controller.zig");

pub const Server = server_file.Server;
pub const TargetId = server_file.TargetId;
pub const Query = server_file.Query;
pub const Profile = server_file.Profile;
pub const SymbolStack = server_file.SymbolStack;
pub const Frame = server_file.Frame;

pub const Controller = controller_file.Controller;
pub const Spec = controller_file.Spec;

test {
    _ = @import("os/lock.zig");
    _ = @import("store/store.zig");
    _ = @import("store/window_ring.zig");
    _ = @import("control/run.zig");
    _ = server_file;
    _ = controller_file;
}
