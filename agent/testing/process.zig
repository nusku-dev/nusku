//! Child processes for the tests to profile. Test-only: nothing outside a `test` block or
//! testing/ may import this, so the agent built for production never contains it.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const timer = @import("../os/timer.zig");
const process = @import("../os/process.zig");
const vdso = @import("../target/vdso.zig");
const elf_sections = @import("../unwind/elf_sections.zig");

/// Forks a child that keeps one CPU busy in its own code for `duration_ms`, then exits.
pub fn burner_spawn(duration_ms: u64) error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        cpu_burn(duration_ms);
        std.c._exit(0);
    }
    return @intCast(pid);
}

/// The vDSO's clock_gettime, called directly.
pub const ClockGettime = *const fn (clock: i32, time: *linux.timespec) callconv(.c) c_int;

/// Forks a child that spends its time inside the vDSO, the kernel code every process maps to
/// read the clock without a system call. `clock_gettime` comes from `vdso_clock_gettime`.
pub fn clock_reader_spawn(duration_ms: u64, clock_gettime: ClockGettime) error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        clock_read_loop(duration_ms, clock_gettime);
        std.c._exit(0);
    }
    return @intCast(pid);
}

/// `__vdso_clock_gettime` in this process, found in the vDSO's own symbol table. A forked child
/// maps the vDSO at the same address, so the pointer is valid there too.
///
/// Not std.os.linux.clock_gettime: in a static musl build Zig's std does not find the vDSO and
/// makes a system call every time, so a loop over it never runs vDSO code.
pub fn vdso_clock_gettime(gpa: std.mem.Allocator) !?ClockGettime {
    var image = (try vdso.read(gpa)) orelse return null;
    defer image.deinit(gpa);

    const symbols_section = (try elf_sections.find(image.bytes, ".dynsym")) orelse return null;
    const names_section = (try elf_sections.find(image.bytes, ".dynstr")) orelse return null;
    const symbols = elf_sections.bytes_of(image.bytes, symbols_section) orelse return null;
    const names = elf_sections.bytes_of(image.bytes, names_section) orelse return null;

    // An Elf64_Sym: name u32, info u8, other u8, section u16, value u64, size u64.
    var offset: usize = 0;
    while (offset + 24 <= symbols.len) : (offset += 24) {
        const name_offset = std.mem.readInt(u32, symbols[offset..][0..4], .little);
        if (name_offset >= names.len) continue;
        const name = std.mem.sliceTo(names[name_offset..], 0);
        if (!std.mem.eql(u8, name, "__vdso_clock_gettime")) continue;

        const value = std.mem.readInt(u64, symbols[offset + 8 ..][0..8], .little);
        // The vDSO is linked at address 0, so a symbol's value is its offset in the mapping.
        const base = std.c.getauxval(std.elf.AT_SYSINFO_EHDR);
        if (base == 0) return null;
        return @ptrFromInt(base + value);
    }
    return null;
}

/// Forks a child that sleeps for a long time without using the CPU.
pub fn sleeper_spawn() error{ForkFailed}!u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        timer.sleep_ms(30 * std.time.ms_per_s);
        std.c._exit(0);
    }
    return @intCast(pid);
}

/// Keeps the calling thread busy for `duration_ms`, in its own code.
///
/// The clock is read only every `burn_iterations_per_check` iterations: reading it is a vDSO
/// call, and a loop that read it every time would spend most of its samples inside the vDSO, so
/// the tests would profile the clock instead of this loop.
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

/// About 50 µs of work per clock read in a Debug build: far finer than any test's duration.
const burn_iterations_per_check = 1 << 16;

/// Reads the clock through the vDSO until `duration_ms` passed. Not inlined, so it is a frame of
/// its own that a walk out of the vDSO must find.
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

/// Kills the child, without waiting for it.
pub fn child_kill(pid: u32) void {
    assert(process.pid_valid(pid));
    _ = linux.kill(@intCast(pid), .KILL);
}

/// Kills the child if it still runs, and waits for it, so it leaves no zombie.
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
