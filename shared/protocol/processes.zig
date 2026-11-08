//! One look at every process of the machine.

pub const ProcessInfo = struct {
    pid: u32,
    name: []const u8,
    user: []const u8,
    /// Empty for a kernel thread.
    command: []const u8,
    threads: u32,
    /// Of one CPU. Null on the first look: it is measured against the look before.
    cpu_percent: ?f32,
    /// Resident (RSS).
    memory_bytes: u64,
    started_unix_ns: u64,
};

pub const Frame = struct {
    /// CLOCK_REALTIME.
    unix_ns: u64,
    /// Since the look before: what `cpu_percent` is measured over. 0 on the first look.
    interval_ns: u64,
    processes: []const ProcessInfo,
};
