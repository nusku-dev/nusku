const std = @import("std");

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

pub const Config = struct {
    pid: u32,
    /// Milliseconds between reports.
    interval_ms: u32,
    /// Seconds to run. 0 means until stopped.
    duration_s: u32,
};

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(Metric),
    interval_ms: u32,
    duration_s: u32,
};
