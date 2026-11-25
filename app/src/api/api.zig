const webui = @import("webui");
const session = @import("session.zig");
const processes = @import("processes.zig");
const profile = @import("profile.zig");
const store = @import("store.zig");
const probes = @import("probes.zig");

pub fn bind(window: webui) !void {
    try session.init();
    try store.init();

    _ = try window.binding("get_processes", processes.get);
    _ = try window.binding("profile_start", profile.start);
    _ = try window.binding("profile_stop", profile.stop);
    _ = try window.binding("profile_launch", profile.launch);
    _ = try window.binding("profile_stream", profile.stream);
    _ = try window.binding("profile_range", profile.range);
    _ = try window.binding("profile_get", profile.get);
    _ = try window.bind("", profile.left);
    _ = try window.binding("store_runs_save", store.save);
    _ = try window.binding("store_runs_list", store.list);
    _ = try window.binding("store_runs_get", store.get);
    _ = try window.binding("store_runs_relabel", store.relabel);
    _ = try window.binding("store_runs_delete", store.delete);
    _ = try window.binding("probe_start", probes.start);
    _ = try window.binding("probe_stop", probes.stop);
    _ = try window.binding("probe_list", probes.list);
    _ = try window.binding("probe_get", probes.get);
}

pub fn deinit() void {
    store.deinit();
    session.deinit();
}

test {
    _ = processes;
    _ = profile;
    _ = store;
    _ = probes;
    _ = @import("json.zig");
    _ = @import("compact.zig");
}
