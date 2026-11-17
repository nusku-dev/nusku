const std = @import("std");
const webui = @import("webui");
const build_options = @import("build_options");
const api = @import("api/api.zig");
const static = @import("static.zig");

const vite_url = "http://127.0.0.1:5173/";

pub fn main() !void {
    webui.setConfig(.multi_client, true);
    const window = webui.newWindow();
    window.setSize(1280, 800);
    window.setMinimumSize(800, 500);
    window.setCenter();

    try api.bind(window);

    if (build_options.dev) {
        try window.setPort(build_options.dev_port);
    } else {
        window.setFileHandler(static.serve);
    }

    try open(window);

    webui.wait();
    webui.clean();
    api.deinit();
}

const show_tries = 3;

fn open(window: webui) !void {
    const content: [:0]const u8 = if (build_options.dev) vite_url else "index.html";
    for (0..show_tries) |_| {
        window.show(content) catch continue;
        return;
    }
    const served = try window.startServer(content);
    const url = if (build_options.dev) vite_url else served;
    std.debug.print("nusku-app: no window opened; open {s} in a browser\n", .{url});
    webui.setTimeout(0);
}

test {
    _ = api;
    _ = static;
}
