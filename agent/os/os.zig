//! The os layer: the system calls every other layer stands on.

pub const process = @import("process.zig");
pub const timer = @import("timer.zig");
pub const poll = @import("poll.zig");
pub const cancel = @import("cancel.zig");
pub const pidfd = @import("pidfd.zig");
pub const perf_event = @import("perf_event.zig");
pub const cpus = @import("cpus.zig");
pub const directory = @import("shared").directory;
pub const anonymous_memory = @import("anonymous_memory.zig");

test {
    _ = process;
    _ = timer;
    _ = poll;
    _ = cancel;
    _ = pidfd;
    _ = perf_event;
    _ = cpus;
    _ = directory;
    _ = anonymous_memory;
}
