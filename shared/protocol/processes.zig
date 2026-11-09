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

/// The whole machine's CPU between two looks, each state a share of every CPU together: 100 is
/// every CPU in that state all the time. Idle is what is left of 100. Counts what the processes
/// do not: interrupts, steal, and the processes that ended between the looks.
pub const MachineCpu = struct {
    /// Everything but idle and iowait: user + system + irq + steal.
    busy_percent: f32,
    /// With nice, and guests' time.
    user_percent: f32,
    system_percent: f32,
    /// Idle, with a disk read or write waiting.
    iowait_percent: f32,
    /// Hardware and software interrupts.
    irq_percent: f32,
    /// Taken by the hypervisor for other machines.
    steal_percent: f32,
};

pub const Machine = struct {
    /// CPUs online. 0: not known.
    cpus: u32 = 0,
    /// Null on the first look, like a process's `cpu_percent`.
    cpu: ?MachineCpu = null,
};

pub const Frame = struct {
    /// CLOCK_REALTIME.
    unix_ns: u64,
    /// Since the look before: what `cpu_percent` is measured over. 0 on the first look.
    interval_ns: u64,
    processes: []const ProcessInfo,
    machine: Machine = .{},
};
