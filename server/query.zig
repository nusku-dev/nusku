//! What a caller asks of the server and what it gets back.

const TargetId = @import("store/store.zig").TargetId;

pub const Query = struct {
    target: TargetId,
    from_unix_ns: u64,
    to_unix_ns: u64,
};

pub const Frame = struct {
    /// The raw address, as the agent reported it.
    address: u64,
    kernel: bool,
    /// Null when the address could not be named: the profile still shows the raw address.
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    /// The binary or library the address is in (its path).
    module: ?[]const u8 = null,
};

pub const SymbolStack = struct {
    samples: u64,
    /// Innermost frame first, kernel frames before user frames.
    frames: []const Frame,
    complete: bool,
};

pub const Profile = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    /// Windows of the target that were lost over its whole life (too big to keep). Not 0: the
    /// profile is missing their samples, which `samples_lost` does not count.
    windows_rejected: u64,
    stacks: []const SymbolStack,
};

/// How the server's symbols are doing, for a status page or a log line.
pub const Stats = struct {
    binaries: usize,
    binaries_bytes: u64,
    /// Waiting for the builder, and being built.
    builds_pending: usize,
    builds_failed: u64,
    uploads_bytes: u64,
};
