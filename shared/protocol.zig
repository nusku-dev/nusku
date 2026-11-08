//! What crosses between the agent and the server.

const message = @import("protocol/message.zig");
const processes = @import("protocol/processes.zig");

pub const Message = message.Message;
pub const Region = message.Region;
pub const binary = @import("protocol/binary.zig");
pub const kernel = @import("protocol/kernel.zig");
pub const ProcessInfo = processes.ProcessInfo;
pub const ProcessFrame = processes.Frame;

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

/// Why a run stopped.
pub const RunStop = enum { duration, target_exited, cancelled };

/// Why a processes watch stopped.
pub const WatchStop = enum { duration, cancelled };

test {
    _ = message;
    _ = binary;
    _ = kernel;
    _ = processes;
}
