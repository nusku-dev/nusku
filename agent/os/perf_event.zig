//! Perf events: the kernel's sampling clocks that run BPF programs.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Error = error{
    /// The CPU is offline: there is nothing to sample on it.
    CpuOffline,
    PermissionDenied,
    NotSupported,
    Unexpected,
};

pub const PerfEvent = struct {
    fd: i32,

    /// A CPU-clock event on one CPU, firing `sample_hz` times a second while any task runs
    /// there (the BPF program picks the target's samples). It starts disabled. Needs root or
    /// CAP_PERFMON.
    ///
    /// CPU clock rather than the cycles counter: it exists on every machine (virtual machines
    /// often have no hardware counters), and its samples measure time, which is what an on-CPU
    /// profile reports.
    pub fn cpu_clock_open(cpu: u32, sample_hz: u32) Error!PerfEvent {
        assert(sample_hz > 0);
        assert(cpu <= std.math.maxInt(i32));

        var attributes = linux.perf_event_attr{
            .type = .SOFTWARE,
            .config = @intFromEnum(linux.PERF.COUNT.SW.CPU_CLOCK),
            .sample_period_or_freq = sample_hz,
            .flags = .{ .disabled = true, .freq = true },
        };
        const result = linux.perf_event_open(
            &attributes,
            -1, // Every process on this CPU.
            @intCast(cpu),
            -1, // No group.
            linux.PERF.FLAG.FD_CLOEXEC,
        );
        return switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            .NODEV => error.CpuOffline,
            .ACCES, .PERM => error.PermissionDenied,
            .NOENT, .OPNOTSUPP, .NOSYS => error.NotSupported,
            else => error.Unexpected,
        };
    }

    pub fn deinit(event: *PerfEvent) void {
        assert(event.fd >= 0);
        _ = linux.close(event.fd);
        event.* = undefined;
    }

    /// Makes every sample of the event run the program.
    pub fn program_attach(event: *const PerfEvent, program_fd: i32) Error!void {
        assert(program_fd >= 0);
        const request = linux.PERF.EVENT_IOC.SET_BPF;
        const result = linux.ioctl(event.fd, request, @intCast(program_fd));
        return ioctl_result(result);
    }

    pub fn enable(event: *const PerfEvent) Error!void {
        const result = linux.ioctl(event.fd, linux.PERF.EVENT_IOC.ENABLE, 0);
        return ioctl_result(result);
    }

    fn ioctl_result(result: usize) Error!void {
        return switch (linux.errno(result)) {
            .SUCCESS => {},
            .ACCES, .PERM => error.PermissionDenied,
            .OPNOTSUPP, .NOTTY => error.NotSupported,
            else => error.Unexpected,
        };
    }
};

test "opens a CPU-clock event (needs root, skipped otherwise)" {
    var event = PerfEvent.cpu_clock_open(0, 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer event.deinit();
    try std.testing.expect(event.fd >= 0);
}
