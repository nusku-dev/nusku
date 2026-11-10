//! The agent: profiles a process with eBPF.

const run_file = @import("run.zig");
const watch_file = @import("watch.zig");

pub const Run = run_file.Run;
pub const RunOptions = run_file.Options;
pub const RunEvent = run_file.Event;

pub const Watch = watch_file.Watch;
pub const WatchOptions = watch_file.Options;
pub const WatchEvent = watch_file.Event;

test {
    _ = @import("os/os.zig");
    _ = @import("elf/elf.zig");
    _ = @import("target/target.zig");
    _ = @import("unwind/unwind.zig");
    _ = @import("metrics/metrics.zig");
    _ = @import("symbols/symbols.zig");
    _ = @import("processes/processes.zig");

    _ = @import("message.zig");
    _ = run_file;
    _ = watch_file;

    _ = @import("testing/e2e/vdso_unwind.zig");
    _ = @import("testing/e2e/cpu_hotplug.zig");
    _ = @import("testing/e2e/go_unwind.zig");
    _ = @import("testing/e2e/watch_processes.zig");
    _ = @import("testing/examples/server_feed.zig");
}
