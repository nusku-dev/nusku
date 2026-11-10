//! One look at every process of the machine.

pub const ProcessInfo = struct {
    pid: u32,
    name: []const u8,
    user: []const u8,
    command: []const u8,
    threads: u32,
    cpu_percent: ?f32,
    memory_bytes: u64,
    started_unix_ns: u64,
};

pub const MachineCpu = struct {
    busy_percent: f32,
    user_percent: f32,
    system_percent: f32,
    iowait_percent: f32,
    irq_percent: f32,
    steal_percent: f32,
};

pub const Machine = struct {
    cpus: u32 = 0,
    cpu: ?MachineCpu = null,
};

pub const Frame = struct {
    unix_ns: u64,
    interval_ns: u64,
    processes: []const ProcessInfo,
    machine: Machine = .{},
};
