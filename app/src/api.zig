//! The functions the UI can call. Each one is bound by name and called from TypeScript through
//! ui/src/lib/backend.ts; keep the two in step.
//!
//! WebUI runs each call on its own thread, so anything shared between calls must be locked.
//! Results go back as strings: JSON for anything structured.

const std = @import("std");
const webui = @import("webui");

pub fn bind(window: webui) !void {
    _ = try window.binding("app_info", appInfo);
}

/// `app_info() -> { name, version }`
fn appInfo(event: webui.Event) void {
    var e = event;
    e.returnString(
        \\{"name":"nusku","version":"0.1.0"}
    );
}
