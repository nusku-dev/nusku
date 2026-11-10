//! What crosses between the agent and the server.

const message = @import("message.zig");
const processes = @import("processes.zig");

pub const Message = message.Message;
pub const Region = message.Region;
pub const binary = @import("binary.zig");
pub const kernel = @import("kernel.zig");
pub const ProcessInfo = processes.ProcessInfo;
pub const ProcessFrame = processes.Frame;
pub const Machine = processes.Machine;
pub const MachineCpu = processes.MachineCpu;

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

pub const RunStop = enum { duration, target_exited, cancelled };

pub const WatchStop = enum { duration, cancelled };

/// Each points into the sender's memory, valid until the next event.
pub const RunEvent = union(enum) {
    report: *const Message,
    binary_offer: binary.Offer,
    binary_begin: *const binary.Header,
    binary_chunk: binary.Chunk,
    binary_end,
    binary_abort,
    stopped: RunStop,
};

pub const Answer = enum { none, wanted, unwanted };

pub const WatchEvent = union(enum) {
    frame: *const ProcessFrame,
    stopped: WatchStop,
};

test {
    _ = message;
    _ = binary;
    _ = kernel;
    _ = processes;
}
