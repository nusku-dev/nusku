const std = @import("std");
const builtin = @import("builtin");
// musl's `struct timespec` contains zero-width bit-fields, so Zig's C import makes it an
// opaque type. We declare the struct and the libc functions we call ourselves instead.
// On 64-bit Linux, time_t and long are both 64 bits, which is what this layout assumes.
comptime {
    std.debug.assert(@sizeOf(usize) == 8);
}

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

const CLOCK_MONOTONIC = 1;
const ESRCH = 3; // "no such process"

extern "c" fn clock_gettime(clock: c_int, ts: *Timespec) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

pub fn nowMs() u64 {
    var ts: Timespec = undefined;
    const rc = clock_gettime(CLOCK_MONOTONIC, &ts);
    std.debug.assert(rc == 0); // CLOCK_MONOTONIC always exists on Linux
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn sleepMs(ms: u64) void {
    const req = Timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = nanosleep(&req, null); // waking early because of a signal is fine
}

pub fn currentPid() u32 {
    return @intCast(getpid());
}

/// A pid of 0 means "profile nothing" to our kernel program, and kill(0, ...) or kill(-1, ...)
/// would mean "my process group" or "everyone", so such values must never get past this check.
pub fn isValidPid(pid: u32) bool {
    return pid > 0 and pid <= std.math.maxInt(i32);
}

/// Signal 0 sends nothing, it only checks. The caller has validated the pid.
pub fn processExists(pid: u32) bool {
    std.debug.assert(isValidPid(pid));
    if (kill(@intCast(pid), 0) == 0) return true;
    // EPERM means it exists but we may not signal it. Only ESRCH means it is gone.
    return std.c._errno().* != ESRCH;
}

test "pid validation" {
    try std.testing.expect(!isValidPid(0));
    try std.testing.expect(isValidPid(1));
    try std.testing.expect(isValidPid(currentPid()));
    try std.testing.expect(!isValidPid(std.math.maxInt(i32) + 1));
}

test "processExists" {
    try std.testing.expect(processExists(currentPid()));
    try std.testing.expect(!processExists(std.math.maxInt(i32)));
}

test "clock advances and sleep sleeps" {
    const a = nowMs();
    sleepMs(20);
    try std.testing.expect(nowMs() - a >= 15);
}

// ------------------------------------------------------------------- pidfd
// A pidfd refers to one specific process. Unlike a pid number, it can never end up
// pointing at a different process after the original exits and its number is reused.

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};
const POLLIN = 0x001;
const POLLNVAL = 0x020;

const ENOSYS = 38;
const SYS_pidfd_open = 434; // the same number on every architecture

extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn poll(fds: *PollFd, nfds: c_ulong, timeout_ms: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

pub const PidFdError = error{
    ProcessNotFound,
    /// The kernel is older than 5.3.
    NotSupported,
    Unexpected,
};

pub const PidFd = struct {
    fd: c_int,

    /// Opens a handle to the process. The caller has validated the pid.
    pub fn open(pid: u32) PidFdError!PidFd {
        std.debug.assert(isValidPid(pid));
        const rc = syscall(SYS_pidfd_open, @as(c_long, pid), @as(c_long, 0));
        if (rc >= 0) return .{ .fd = @intCast(rc) };
        return switch (std.c._errno().*) {
            ESRCH => error.ProcessNotFound,
            ENOSYS => error.NotSupported,
            else => error.Unexpected,
        };
    }

    /// True once the process has exited. A process that has exited but has not been reaped
    /// by its parent yet counts as exited.
    pub fn hasExited(self: PidFd) bool {
        var pfd = PollFd{ .fd = self.fd, .events = POLLIN, .revents = 0 };
        const rc = poll(&pfd, 1, 0); // timeout 0: only look, never wait
        std.debug.assert(rc >= 0);
        std.debug.assert(pfd.revents & POLLNVAL == 0); // our own descriptor must be valid
        return rc > 0 and pfd.revents & POLLIN != 0;
    }

    pub fn deinit(self: *PidFd) void {
        _ = close(self.fd);
        self.* = undefined;
    }
};

// For the tests below.
const libc = struct {
    extern "c" fn fork() c_int;
    extern "c" fn _exit(status: c_int) noreturn;
    extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
};

test "pidfd: our own process has not exited" {
    var pidfd = try PidFd.open(currentPid());
    defer pidfd.deinit();
    try std.testing.expect(!pidfd.hasExited());
}

test "pidfd: a pid that does not exist" {
    try std.testing.expectError(error.ProcessNotFound, PidFd.open(std.math.maxInt(i32)));
}

test "pidfd: notices when a process exits" {
    const child = libc.fork();
    if (child == 0) libc._exit(0); // the child leaves at once
    try std.testing.expect(child > 0);

    var pidfd = try PidFd.open(@intCast(child));
    defer pidfd.deinit();

    const until = nowMs() + 2000;
    while (!pidfd.hasExited() and nowMs() < until) sleepMs(5);
    const exited = pidfd.hasExited();
    _ = libc.waitpid(child, null, 0); // reap it either way, so no zombie is left behind
    try std.testing.expect(exited);
}

// ------------------------------------------------------------ event loop pieces

const EINTR = 4;
const EAGAIN = 11;
const POLLHUP = 0x010;
const POLLERR = 0x008;

// The same values on x86_64 and aarch64 Linux.
const TFD_CLOEXEC = 0o2000000;
const TFD_NONBLOCK = 0o4000;
const SFD_CLOEXEC = 0o2000000;
const SFD_NONBLOCK = 0o4000;
const SIG_BLOCK = 0;
const SIG_SETMASK = 2;

const Itimerspec = extern struct {
    interval: Timespec,
    value: Timespec,
};

/// musl's sigset_t: 1024 bits. A glibc build would need a different layout.
const SigSet = extern struct { bits: [16]u64 };

comptime {
    std.debug.assert(@sizeOf(SigSet) == 128);
    std.debug.assert(builtin.abi == .musl);
}

extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn timerfd_create(clock: c_int, flags: c_int) c_int;
extern "c" fn timerfd_settime(fd: c_int, flags: c_int, new: *const Itimerspec, old: ?*Itimerspec) c_int;
extern "c" fn sigemptyset(set: *SigSet) c_int;
extern "c" fn sigaddset(set: *SigSet, signo: c_int) c_int;
extern "c" fn sigprocmask(how: c_int, set: ?*const SigSet, old: ?*SigSet) c_int;
extern "c" fn signalfd(fd: c_int, mask: *const SigSet, flags: c_int) c_int;
extern "c" fn raise(sig: c_int) c_int;

pub const FdError = error{Unexpected};

fn msToTimespec(ms: u64) Timespec {
    return .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
}

/// A timer that becomes readable when it expires.
pub const TimerFd = struct {
    fd: c_int,

    /// Fires `first_ms` from now and then every `period_ms`; with `period_ms == 0` it fires once.
    pub fn start(first_ms: u32, period_ms: u32) FdError!TimerFd {
        std.debug.assert(first_ms > 0); // a zero first expiration would switch the timer off
        const fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
        if (fd < 0) return error.Unexpected;
        const spec = Itimerspec{ .interval = msToTimespec(period_ms), .value = msToTimespec(first_ms) };
        if (timerfd_settime(fd, 0, &spec, null) < 0) {
            _ = close(fd);
            return error.Unexpected;
        }
        return .{ .fd = fd };
    }

    /// How many times it fired since the last call. Ticks that were missed are counted, not lost.
    pub fn expirations(self: TimerFd) u64 {
        var count: u64 = 0;
        const n = read(self.fd, &count, @sizeOf(u64));
        if (n == @sizeOf(u64)) return count;
        std.debug.assert(n < 0 and std.c._errno().* == EAGAIN); // nothing since the last read
        return 0;
    }

    pub fn deinit(self: *TimerFd) void {
        _ = close(self.fd);
        self.* = undefined;
    }
};

/// Turns signals into readable events. While it exists, the listed signals no longer kill or
/// interrupt the process; they wait here until read. The previous signal mask is restored on
/// deinit. This uses sigprocmask, which only affects the calling thread: when we add threads,
/// set this up before spawning them so they inherit it.
pub const SignalFd = struct {
    fd: c_int,
    previous_mask: SigSet,

    pub fn init(signals: []const c_int) FdError!SignalFd {
        var mask: SigSet = undefined;
        _ = sigemptyset(&mask);
        for (signals) |s| {
            const rc = sigaddset(&mask, s);
            std.debug.assert(rc == 0); // a bad signal number is a bug
        }
        var previous: SigSet = undefined;
        if (sigprocmask(SIG_BLOCK, &mask, &previous) != 0) return error.Unexpected;
        const fd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
        if (fd < 0) {
            _ = sigprocmask(SIG_SETMASK, &previous, null);
            return error.Unexpected;
        }
        return .{ .fd = fd, .previous_mask = previous };
    }

    /// The next signal that arrived, or null if none is waiting.
    pub fn next(self: SignalFd) ?c_int {
        // struct signalfd_siginfo is 128 bytes and starts with the signal number as a u32.
        var info: [128]u8 align(8) = undefined;
        const n = read(self.fd, &info, info.len);
        if (n < 0) {
            std.debug.assert(std.c._errno().* == EAGAIN);
            return null;
        }
        std.debug.assert(n == info.len);
        return @intCast(std.mem.readInt(u32, info[0..4], .little));
    }

    pub fn deinit(self: *SignalFd) void {
        _ = close(self.fd);
        _ = sigprocmask(SIG_SETMASK, &self.previous_mask, null);
        self.* = undefined;
    }
};

const max_poll_fds = 8;

/// Waits until at least one of `fds` is readable, or `timeout_ms` has passed (-1 waits without
/// limit). Sets `ready[i]` for each readable descriptor and returns how many there are.
pub fn waitReadable(fds: []const c_int, ready: []bool, timeout_ms: c_int) usize {
    std.debug.assert(fds.len > 0 and fds.len <= max_poll_fds and ready.len == fds.len);
    var pfds: [max_poll_fds]PollFd = undefined;
    for (fds, 0..) |fd, i| pfds[i] = .{ .fd = fd, .events = POLLIN, .revents = 0 };

    const rc = poll(&pfds[0], fds.len, timeout_ms);
    if (rc < 0) {
        std.debug.assert(std.c._errno().* == EINTR); // interrupted: report "nothing ready"
        @memset(ready, false);
        return 0;
    }
    var count: usize = 0;
    for (pfds[0..fds.len], ready) |p, *r| {
        std.debug.assert(p.revents & POLLNVAL == 0); // our own descriptors must be valid
        r.* = p.revents & (POLLIN | POLLHUP | POLLERR) != 0;
        if (r.*) count += 1;
    }
    return count;
}

test "timerfd: a periodic timer fires again and again" {
    var timer = try TimerFd.start(30, 30);
    defer timer.deinit();

    var ready = [_]bool{false};
    const started = nowMs();
    try std.testing.expectEqual(@as(usize, 1), waitReadable(&.{timer.fd}, &ready, 500));
    try std.testing.expect(nowMs() - started >= 20);
    try std.testing.expect(timer.expirations() >= 1);

    sleepMs(100);
    try std.testing.expect(timer.expirations() >= 2); // missed ticks are counted
}

test "timerfd: a one-shot timer fires once" {
    var timer = try TimerFd.start(30, 0);
    defer timer.deinit();

    var ready = [_]bool{false};
    try std.testing.expectEqual(@as(usize, 1), waitReadable(&.{timer.fd}, &ready, 500));
    try std.testing.expectEqual(@as(u64, 1), timer.expirations());

    sleepMs(80);
    try std.testing.expectEqual(@as(u64, 0), timer.expirations());
}

test "waitReadable times out when nothing is ready" {
    var timer = try TimerFd.start(1000, 0);
    defer timer.deinit();

    var ready = [_]bool{true}; // must be cleared by the call
    try std.testing.expectEqual(@as(usize, 0), waitReadable(&.{timer.fd}, &ready, 20));
    try std.testing.expect(!ready[0]);
}

test "signalfd: a blocked signal arrives as a readable event" {
    const SIGUSR1 = 10;
    var sig = try SignalFd.init(&.{SIGUSR1});
    defer sig.deinit();

    try std.testing.expectEqual(@as(?c_int, null), sig.next()); // nothing yet

    _ = raise(SIGUSR1);
    var ready = [_]bool{false};
    try std.testing.expectEqual(@as(usize, 1), waitReadable(&.{sig.fd}, &ready, 500));
    try std.testing.expectEqual(@as(?c_int, SIGUSR1), sig.next());
    try std.testing.expectEqual(@as(?c_int, null), sig.next());
}

test "one wait covers several descriptors" {
    var soon = try TimerFd.start(20, 0);
    defer soon.deinit();
    var later = try TimerFd.start(5000, 0);
    defer later.deinit();

    var ready = [_]bool{ false, false };
    try std.testing.expectEqual(@as(usize, 1), waitReadable(&.{ soon.fd, later.fd }, &ready, 500));
    try std.testing.expect(ready[0] and !ready[1]);
}
