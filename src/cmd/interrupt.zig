//! Ctrl-C and SIGTERM stop what the client runs.

const std = @import("std");
const client = @import("client");

pub fn arm() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn handle(_: std.posix.SIG) callconv(.c) void {
    client.stop();
}
