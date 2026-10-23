const std = @import("std");
const cli = @import("cli");
const log = @import("log");
const cmd = @import("cmd/root.zig");

pub fn main(init: std.process.Init) u8 {
    const root = cmd.root;
    const arena = init.arena.allocator();

    // Drop argv[0]: the framework only wants what the user typed after it.
    const raw = init.minimal.args.toSlice(arena) catch return 1;
    const argv = arena.alloc([]const u8, raw.len - 1) catch return 1;
    for (raw[1..], argv) |src, *dst| dst.* = src;

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);

    var logger = log.Logger.init(.{
        .writer = &err.interface,
        .io = init.io,
        .color = log.shouldColor(init.io, std.Io.File.stderr(), init.environ_map.get("NO_COLOR") != null),
    });

    log.setDefault(&logger);
    defer log.clearDefault();

    return cli.execute(&root, argv, .{
        .allocator = init.gpa,
        .io = init.io,
        .stderr = &err.interface,
        .stdout = &out.interface,
        .env = cli.EnvLookup.fromMap(init.environ_map),
        .version = "0.1.0",
    });
}

test {
    _ = @import("clients/agent.zig");
}
