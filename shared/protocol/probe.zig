//! What a function probe reports: how often a function was called, and how long it took.

pub const buckets = 64;

/// Counted since the probe was attached.
pub const Totals = struct {
    calls: u64 = 0,
    /// Returns timed: their durations are in `total_ns`, `max_ns` and `histogram`.
    timed: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    /// Returns of calls nested too deep to time.
    untimed: u64 = 0,
    /// Returns of calls already running when the probe was attached.
    unmatched: u64 = 0,
    /// Entries with no room to keep their start.
    dropped: u64 = 0,
    /// Bucket b holds the calls that took [2^(b-1), 2^b) nanoseconds.
    histogram: [buckets]u64 = @splat(0),
};

/// Where the probe is.
pub const Info = struct {
    pid: u32,
    function: []const u8,
    /// The file as the process maps it.
    path: []const u8,
    offset: u64,
    size: u64,
};

pub const Report = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    totals: Totals,
};
