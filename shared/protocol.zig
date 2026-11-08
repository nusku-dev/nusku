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

/// What a profiling run gives, in order: reports, the binaries' conversation, and its end.
/// Each points into the sender's memory, valid until the next event.
pub const RunEvent = union(enum) {
    report: *const Message,
    /// Answered with `Answer`: the binary is sent only if wanted.
    binary_offer: binary.Offer,
    binary_begin: *const binary.Header,
    binary_chunk: binary.Chunk,
    binary_end,
    /// The binary begun will not end.
    binary_abort,
    /// The last event.
    stopped: RunStop,
};

/// The receiver's reply to an event. `unwanted` to an offer declines the binary; during a
/// transfer it stops it.
pub const Answer = enum { none, wanted, unwanted };

/// What a processes watch gives: a frame per interval, then its end.
pub const WatchEvent = union(enum) {
    /// The first has no `cpu_percent`: CPU is measured against the frame before.
    frame: *const ProcessFrame,
    /// The last event.
    stopped: WatchStop,
};

test {
    _ = message;
    _ = binary;
    _ = kernel;
    _ = processes;
}
