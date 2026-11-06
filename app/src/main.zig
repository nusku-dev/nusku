//! The desktop app: a WebUI window whose page is the React UI in ui/.
//!
//! Release build: the UI is embedded in the binary and served from memory (see static.zig).
//! Dev build (`-Ddev`): the window loads the Vite dev server, so UI edits reload instantly.

const std = @import("std");
const webui = @import("webui");
const build_options = @import("build_options");
const api = @import("api.zig");
const static = @import("static.zig");

/// Must match `server.port` in ui/vite.config.ts.
const vite_url = "http://127.0.0.1:5173/";

pub fn main() !void {
    const window = webui.newWindow();
    window.setSize(1280, 800);
    window.setMinimumSize(800, 500);
    window.setCenter();

    try api.bind(window);

    if (build_options.dev) {
        // Vite proxies `/webui.js` to this port, so it has to be fixed.
        try window.setPort(build_options.dev_port);
        try window.show(vite_url);
    } else {
        window.setFileHandler(static.serve);
        try window.show("index.html");
    }

    webui.wait();
    webui.clean();
}

test {
    std.testing.refAllDecls(@This());
}
