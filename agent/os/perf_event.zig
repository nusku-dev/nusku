//! Perf events: the kernel's sampling clocks that run BPF programs.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub const Error = error{
    CpuOffline,
    ProcessNotFound,
    PermissionDenied,
    NotSupported,
    Unexpected,
};

pub const PerfEvent = struct {
    fd: i32,

    /// Needs root or CAP_PERFMON.
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
            -1,
            @intCast(cpu),
            -1,
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

    /// A probe on the instruction at `offset` in the file at `path`, in process `pid` only:
    /// at its entry, or with `on_return` when the function returns. Needs root or CAP_PERFMON.
    pub fn uprobe_open(pid: u32, path: [:0]const u8, offset: u64, on_return: bool) Error!PerfEvent {
        assert(pid > 0 and pid <= std.math.maxInt(i32));
        const pmu = try uprobe_pmu();
        var attributes = linux.perf_event_attr{
            .type = @enumFromInt(pmu.type),
            .config = if (on_return) @as(u64, 1) << pmu.return_bit else 0,
            .config1 = @intFromPtr(path.ptr),
            .config2 = offset,
            .sample_period_or_freq = 1,
            .flags = .{ .disabled = true },
        };
        const result = linux.perf_event_open(
            &attributes,
            @intCast(pid),
            -1,
            -1,
            linux.PERF.FLAG.FD_CLOEXEC,
        );
        return switch (linux.errno(result)) {
            .SUCCESS => .{ .fd = @intCast(result) },
            .ACCES, .PERM => error.PermissionDenied,
            .NOENT, .OPNOTSUPP, .NOSYS, .INVAL => error.NotSupported,
            .SRCH => error.ProcessNotFound,
            else => error.Unexpected,
        };
    }

    pub fn deinit(event: *PerfEvent) void {
        assert(event.fd >= 0);
        _ = linux.close(event.fd);
        event.* = undefined;
    }

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

const Pmu = struct { type: u32, return_bit: u6 };

/// The uprobe event type is chosen by the kernel at boot, and so is the bit for a return.
fn uprobe_pmu() Error!Pmu {
    var buffer: [64]u8 = undefined;
    const type_text = sysfs_read("/sys/bus/event_source/devices/uprobe/type", &buffer) orelse
        return error.NotSupported;
    const pmu_type = std.fmt.parseInt(u32, type_text, 10) catch return error.NotSupported;
    const format = "/sys/bus/event_source/devices/uprobe/format/retprobe";
    const bit_text = sysfs_read(format, &buffer) orelse return error.NotSupported;
    if (!std.mem.startsWith(u8, bit_text, "config:")) return error.NotSupported;
    const bit = std.fmt.parseInt(u6, bit_text["config:".len..], 10) catch return error.NotSupported;
    return .{ .type = pmu_type, .return_bit = bit };
}

fn sysfs_read(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const opened = linux.open(path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const got = linux.read(fd, buffer.ptr, buffer.len);
    if (linux.errno(got) != .SUCCESS) return null;
    return std.mem.trim(u8, buffer[0..got], " \n");
}

test "the uprobe event type and its return bit are read from sysfs" {
    const pmu = uprobe_pmu() catch return error.SkipZigTest;
    try std.testing.expect(pmu.type > @intFromEnum(linux.PERF.TYPE.MAX));
}

test "opens a CPU-clock event (needs root, skipped otherwise)" {
    var event = PerfEvent.cpu_clock_open(0, 99) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer event.deinit();
    try std.testing.expect(event.fd >= 0);
}
