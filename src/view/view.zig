//! The view layer: what the commands print. A toolbox of two views, each drawn on a writer:
//!   profile    the report (summary, top functions, call tree), its live version, and folded
//!              stacks for flame graphs
//!   processes  the table of `nusku ps`
//! Stands on term.

pub const profile = @import("profile.zig");
pub const processes = @import("processes.zig");

test {
    _ = profile;
    _ = processes;
}
