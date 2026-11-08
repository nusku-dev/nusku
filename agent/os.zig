//! The os layer: the system calls every other layer stands on. A toolbox rather than one
//! struct: each tool is small, and each layer above takes the few it needs. Imports nothing
//! of the agent.

pub const process = @import("os/process.zig");
pub const timer = @import("os/timer.zig");
pub const poll = @import("os/poll.zig");
pub const cancel = @import("os/cancel.zig");
pub const pidfd = @import("os/pidfd.zig");
pub const perf_event = @import("os/perf_event.zig");
pub const cpus = @import("os/cpus.zig");
pub const directory = @import("os/directory.zig");
pub const anonymous_memory = @import("os/anonymous_memory.zig");

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
