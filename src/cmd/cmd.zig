//! The cmd layer: the commands of `nusku`, each reading its flags, asking the client, and
//! printing through a view:
//!   prof   profile one process, live, then its report
//!   ps     every process of the machine, live
//!   flags  the flags every command shares
//! Stands on term, client and view.

const cli = @import("cli");
const prof = @import("prof.zig");
const ps = @import("ps.zig");

/// Read by every command: `flags.log_apply`.
const flags: []const cli.Flag = &.{
    .{ .name = "verbose", .short = 'v', .kind = .bool, .help = "Same as --log-level=debug" },
    .{
        .name = "log-level",
        .help = "trace, debug, info, warn, error, off",
        .env = "NUSKU_LOG_LEVEL",
    },
    .{ .name = "log-format", .help = "text, logfmt or json", .env = "NUSKU_LOG_FORMAT" },
};

pub const root: cli.Command = .{
    .name = "nusku",
    .short = "A continuous profiling system for Linux, built in Zig, with eBPF doing the watching",
    .long =
    \\Nusku is a continuous profiling system for Linux. It watches a running process
    \\and shows you what it is actually doing, live, instead of leaving you to guess
    \\from a graph of CPU percentage that goes up and down with no explanation.
    ,
    .persistent_flags = flags,
    .subcommands = &.{ &prof.cmd, &ps.cmd },
};

test {
    _ = prof;
    _ = ps;
    _ = @import("flags.zig");
}
