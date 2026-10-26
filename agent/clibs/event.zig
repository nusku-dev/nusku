const std = @import("std");
const c = @import("import.zig").clibs;
const err = @import("error.zig");

const Err = err.Error;
const fromErrno = err.fromErrno;

/// First 72 bytes of struct perf_event_attr (PERF_ATTR_SIZE_VER1); the kernel accepts shorter
/// layouts. The C struct is a bit-field maze, so we set the one flag we need as a raw bit.
const PerfEventAttr = extern struct {
    type: u32,
    size: u32,
    config: u64,
    sample_freq: u64, // shares space with sample_period; used because FLAG_FREQ is set
    sample_type: u64,
    read_format: u64,
    flags: u64, // the bit-field word: disabled is bit 0, freq is bit 10
    wakeup_events: u32,
    bp_type: u32,
    config1: u64,
    config2: u64,
};

comptime {
    std.debug.assert(@sizeOf(PerfEventAttr) == 72);
    std.debug.assert(@offsetOf(PerfEventAttr, "flags") == 40);
}

const PERF_TYPE_SOFTWARE = 1;
const PERF_COUNT_SW_CPU_CLOCK = 0;
const FLAG_DISABLED: u64 = 1 << 0;
const FLAG_FREQ: u64 = 1 << 10;
const PERF_FLAG_FD_CLOEXEC: c_long = 1 << 3;

// ioctl requests from linux/perf_event.h: _IO('$', 0) and _IOW('$', 8, __u32).
const PERF_EVENT_IOC_ENABLE = 0x2400;
const PERF_EVENT_IOC_SET_BPF = 0x40042408;

pub const Error = Err || error{CpuOffline};

pub const Event = struct {
    fd: c_int,

    /// A CPU-clock event on one CPU: fires `hz` times a second for every process running
    /// there (the BPF program filters by pid). Starts disabled. Needs root or CAP_PERFMON.
    pub fn openCpuClock(cpu: u32, hz: u32) Error!Event {
        std.debug.assert(hz > 0);

        var attr = std.mem.zeroes(PerfEventAttr);
        attr.type = PERF_TYPE_SOFTWARE;
        attr.size = @sizeOf(PerfEventAttr);
        attr.config = PERF_COUNT_SW_CPU_CLOCK;
        attr.sample_freq = hz;
        attr.flags = FLAG_DISABLED | FLAG_FREQ;

        const rc = c.syscall(
            c.SYS_perf_event_open,
            @intFromPtr(&attr),
            @as(c_long, -1), // pid -1 together with a cpu = every process on that cpu
            @as(c_long, cpu),
            @as(c_long, -1), // no group
            PERF_FLAG_FD_CLOEXEC,
        );
        if (rc < 0) {
            const e = std.c._errno().*;
            if (e == c.ENODEV) return error.CpuOffline;
            return fromErrno(e);
        }
        std.debug.assert(rc <= std.math.maxInt(c_int));
        return .{ .fd = @intCast(rc) };
    }

    /// Makes the event run the BPF program on every sample.
    pub fn attach(self: Event, program_fd: c_int) Error!void {
        std.debug.assert(program_fd >= 0);
        if (c.ioctl(self.fd, PERF_EVENT_IOC_SET_BPF, program_fd) < 0) {
            return fromErrno(std.c._errno().*);
        }
    }

    pub fn enable(self: Event) Error!void {
        if (c.ioctl(self.fd, PERF_EVENT_IOC_ENABLE, @as(c_int, 0)) < 0) {
            return fromErrno(std.c._errno().*);
        }
    }

    pub fn deinit(self: *Event) void {
        _ = c.close(self.fd);
        self.* = undefined;
    }
};

test "opens a CPU-clock event (needs root, skipped otherwise)" {
    var event = Event.openCpuClock(0, 99) catch |erro| switch (erro) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return erro,
    };
    defer event.deinit();
    try std.testing.expect(event.fd >= 0);
}
