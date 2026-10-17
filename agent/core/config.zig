const std = @import("std");
const Cancel = @import("cancel.zig").Cancel;

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };

pub const Config = struct {
    pid: u32,
    /// Milliseconds between reports.
    interval_ms: u32,
    /// Seconds to run. 0 means until stopped.
    duration_s: u32,
    /// Lets another thread stop the run. Null means the run cannot be cancelled.
    cancel: ?*const Cancel = null,
};

pub const Options = struct {
    pid: u32,
    metrics: std.EnumSet(Metric),
    interval_ms: u32,
    duration_s: u32,
    cancel: ?*const Cancel = null,
};
