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
        try window.show(vite_url);
    } else {
        window.setFileHandler(static.serve);
        try window.show("index.html");
    }

    webui.wait();
    webui.clean();
    api.deinit();
}

test {
    _ = api;
    _ = static;
}
