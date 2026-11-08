//! What a caller asks of the server and what it gets back.

const TargetId = @import("store/store.zig").TargetId;

pub const Query = struct {
    target: TargetId,
    from_unix_ns: u64,
    to_unix_ns: u64,
};

pub const Frame = struct {
    /// As the agent reported it.
    address: u64,
    kernel: bool,
    /// Null when it could not be named.
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    /// The path of the binary it is in.
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
    /// Lost over the target's life, too big to keep: their samples are not in `samples_lost`.
    windows_rejected: u64,
    stacks: []const SymbolStack,
};

/// How the server's symbols are doing.
pub const Stats = struct {
    binaries: usize,
    binaries_bytes: u64,
    /// Waiting for the builder, or being built.
    builds_pending: usize,
    builds_failed: u64,
    uploads_bytes: u64,
};
