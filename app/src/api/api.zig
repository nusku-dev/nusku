const webui = @import("webui");
const processes = @import("processes.zig");

pub fn bind(window: webui) !void {
    _ = try window.binding("get_processes", processes.get);
}

test {
    _ = processes;
}
