//! The view layer: what the commands print.

pub const profile = @import("profile.zig");
pub const processes = @import("processes.zig");
pub const probe = @import("probe.zig");

test {
    _ = profile;
    _ = processes;
    _ = probe;
}
