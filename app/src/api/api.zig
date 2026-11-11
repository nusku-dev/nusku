const webui = @import("webui");
const session = @import("session.zig");
const processes = @import("processes.zig");
const profile = @import("profile.zig");

pub fn bind(window: webui) !void {
    try session.init();
    _ = try window.binding("get_processes", processes.get);
    _ = try window.binding("profile_start", profile.start);
    _ = try window.binding("profile_stop", profile.stop);
    _ = try window.binding("profile_stream", profile.stream);
    _ = try window.bind("", profile.left);
}

pub fn deinit() void {
    session.deinit();
}

test {
    _ = processes;
    _ = profile;
}
