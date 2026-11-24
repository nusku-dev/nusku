//! Child processes for the tests to profile.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const timer = @import("../os/os.zig").timer;
const process = @import("../os/os.zig").process;
const vdso = @import("../target/vdso.zig");
const elf = @import("shared").elf;

pub fn burner_spawn(duration_ms: u64) error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        cpu_burn(duration_ms);
        std.c._exit(0);
    }
    return @intCast(pid);
}

pub const ClockGettime = *const fn (clock: i32, time: *linux.timespec) callconv(.c) c_int;

pub fn clock_reader_spawn(duration_ms: u64, clock_gettime: ClockGettime) error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        clock_read_loop(duration_ms, clock_gettime);
        std.c._exit(0);
    }
    return @intCast(pid);
}

pub fn vdso_clock_gettime(gpa: std.mem.Allocator) !?ClockGettime {
    var image = (try vdso.read(gpa)) orelse return null;
    defer image.deinit(gpa);

    const symbols_section = (try elf.find(image.bytes, ".dynsym")) orelse return null;
    const names_section = (try elf.find(image.bytes, ".dynstr")) orelse return null;
    const symbols = elf.bytes_of(image.bytes, symbols_section) orelse return null;
    const names = elf.bytes_of(image.bytes, names_section) orelse return null;

    var offset: usize = 0;
    while (offset + 24 <= symbols.len) : (offset += 24) {
        const name_offset = std.mem.readInt(u32, symbols[offset..][0..4], .little);
        if (name_offset >= names.len) continue;
        const name = std.mem.sliceTo(names[name_offset..], 0);
        if (!std.mem.eql(u8, name, "__vdso_clock_gettime")) continue;

        const value = std.mem.readInt(u64, symbols[offset + 8 ..][0..8], .little);
        const base = std.c.getauxval(std.elf.AT_SYSINFO_EHDR);
        if (base == 0) return null;
        return @ptrFromInt(base + value);
    }
    return null;
}

pub fn sleeper_spawn() error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        timer.sleep_ms(30 * std.time.ms_per_s);
        std.c._exit(0);
    }
    return @intCast(pid);
}

pub fn cpu_burn(duration_ms: u64) void {
    const deadline_ns = timer.monotonic_ns() + duration_ms * std.time.ns_per_ms;
    var counter: u64 = 0;
    while (timer.monotonic_ns() < deadline_ns) {
        var iteration: u32 = 0;
        while (iteration < burn_iterations_per_check) : (iteration += 1) {
            counter +%= iteration;
            std.mem.doNotOptimizeAway(counter);
        }
    }
}

const burn_iterations_per_check = 1 << 16;

noinline fn clock_read_loop(duration_ms: u64, clock_gettime: ClockGettime) void {
    const deadline_ns = timer.monotonic_ns() + duration_ms * std.time.ns_per_ms;
    var time: linux.timespec = undefined;
    while (true) {
        _ = clock_gettime(@intFromEnum(linux.clockid_t.MONOTONIC), &time);
        const now_ns = @as(u64, @intCast(time.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(time.nsec));
        if (now_ns >= deadline_ns) break;
    }
}

pub fn cpu_pin(pid: u32, cpu: u32) !void {
    assert(cpu < linux.CPU_SETSIZE * 8);
    var set = std.mem.zeroes(linux.cpu_set_t);
    const word_bits = @bitSizeOf(usize);
    set[cpu / word_bits] |= @as(usize, 1) << @intCast(cpu % word_bits);
    try linux.sched_setaffinity(@intCast(pid), &set);
}

pub fn cpu_online_set(cpu: u32, online: bool) !void {
    assert(cpu > 0);
    var path_buffer: [64]u8 = undefined;
    const path_format = "/sys/devices/system/cpu/cpu{d}/online";
    const path = try std.fmt.bufPrintZ(&path_buffer, path_format, .{cpu});
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    if (fd < 0) return error.CpuOnlineOpenFailed;
    defer _ = std.c.close(fd);
    const value: []const u8 = if (online) "1" else "0";
    if (std.c.write(fd, value.ptr, value.len) != 1) return error.CpuOnlineWriteFailed;
}

/// Copies `source` to `copy` and runs the copy with `argv`, until it has replaced the child.
pub fn copy_spawn(
    source: [:0]const u8,
    copy: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) !u32 {
    try file_copy(source, copy);
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.execve(copy, argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    const process_maps = @import("../target/process_maps.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        _ = arena.reset(.retain_capacity);
        const mappings = process_maps.read(arena.allocator(), @intCast(pid)) catch &.{};
        for (mappings) |mapping| {
            if (std.mem.eql(u8, mapping.path, copy)) return @intCast(pid);
        }
        timer.sleep_ms(5);
    }
    child_reap(@intCast(pid));
    return error.ExecTimeout;
}

fn file_copy(source: [:0]const u8, copy: [:0]const u8) !void {
    const from = std.c.open(source.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (from < 0) return error.CopyFailed;
    defer _ = std.c.close(from);
    const flags = linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const to = std.c.open(copy.ptr, flags, @as(std.c.mode_t, 0o755));
    if (to < 0) return error.CopyFailed;
    defer _ = std.c.close(to);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const got = std.c.read(from, &buffer, buffer.len);
        if (got < 0) return error.CopyFailed;
        if (got == 0) return;
        const bytes: usize = @intCast(got);
        if (std.c.write(to, &buffer, bytes) != got) return error.CopyFailed;
    }
}

/// The function the probe tests watch: spins for about `rounds` iterations, then calls
/// itself until it is `depth` calls deep.
pub noinline fn probed_function(rounds: u64, depth: u32) u64 {
    var sum: u64 = if (depth > 1) probed_function(rounds, depth - 1) else 0;
    var i: u64 = 0;
    while (i < rounds) : (i += 1) {
        sum +%= i *% 2654435761;
        std.mem.doNotOptimizeAway(&sum);
    }
    return sum;
}

pub const Caller = struct { pid: u32, start_fd: i32 };

/// A child that calls `probed_function` `calls` times once something is written to `start_fd`.
pub fn caller_spawn(calls: u32, rounds: u64, depth: u32) !Caller {
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = linux.close(pipe[1]);
        var byte: [1]u8 = undefined;
        _ = linux.read(pipe[0], &byte, 1);
        var i: u32 = 0;
        while (i < calls) : (i += 1) std.mem.doNotOptimizeAway(probed_function(rounds, depth));
        std.c._exit(0);
    }
    _ = linux.close(pipe[0]);
    return .{ .pid = @intCast(pid), .start_fd = pipe[1] };
}

pub fn caller_start(caller: Caller) void {
    _ = linux.write(caller.start_fd, "s", 1);
    _ = linux.close(caller.start_fd);
}

pub fn child_wait(pid: u32) void {
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

pub fn child_kill(pid: u32) void {
    assert(process.pid_valid(pid));
    _ = linux.kill(@intCast(pid), .KILL);
}

pub fn zombie_wait(pid: u32) !void {
    const process_maps = @import("../target/process_maps.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        _ = arena.reset(.retain_capacity);
        const mappings = try process_maps.read(arena.allocator(), pid);
        if (mappings.len == 0) return;
        timer.sleep_ms(10);
    }
    return error.ZombieTimeout;
}

pub fn child_reap(pid: u32) void {
    child_kill(pid);
    var status: u32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
}

test "the vDSO's clock_gettime, called directly, tells the same time as the system call" {
    const clock_gettime = (try vdso_clock_gettime(std.testing.allocator)) orelse
        return error.SkipZigTest;
    var time: linux.timespec = undefined;
    const monotonic = @intFromEnum(linux.clockid_t.MONOTONIC);
    try std.testing.expectEqual(@as(c_int, 0), clock_gettime(monotonic, &time));
    const vdso_ns = @as(u64, @intCast(time.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(time.nsec));
    const syscall_ns = timer.monotonic_ns();
    try std.testing.expect(syscall_ns >= vdso_ns);
    try std.testing.expect(syscall_ns - vdso_ns < std.time.ns_per_s);
}
