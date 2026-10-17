const std = @import("std");
const timer = @import("timer.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn syscall(number: c_long, ...) c_long;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pread(fd: c_int, buf: *anyopaque, count: usize, offset: i64) isize;
extern "c" fn read(fd: c_int, buf: *anyopaque, count: usize) isize;
extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;

const SYS_pidfd_open = 434;

const EPERM = 1;
const ENOENT = 2;
const ESRCH = 3;
const EINTR = 4;
const EACCES = 13;
const ENOSYS = 38;

pub const CLOCK_MONOTONIC = 1;
/// A pid of 0 means "profile nothing" to our kernel program, and kill(0, ...) or kill(-1, ...)
/// would mean "my process group" or "everyone", so such values must never get past this check.
pub fn isValidPid(pid: u32) bool {
    return pid > 0 and pid <= std.math.maxInt(i32);
}
/// A pidfd refers to this exact process, so a recycled pid number can never fool us. It becomes
/// readable when the process exits, and opening one fails for a process that does not exist.
pub fn openPidfd(pid: u32) !c_int {
    const rc = syscall(SYS_pidfd_open, @as(c_long, pid), @as(c_long, 0));
    if (rc < 0) return switch (errno()) {
        ESRCH => error.ProcessNotFound,
        EPERM => error.PermissionDenied,
        ENOSYS => error.NotSupported,
        else => error.Unexpected,
    };
    const pid_fd: c_int = @intCast(rc);
    return pid_fd;
}

pub fn fdClose(fd: c_int) void {
    _ = close(fd);
}

fn errno() c_int {
    return std.c._errno().*;
}

const O_RDONLY = 0;
const O_CLOEXEC = 0o2000000;

pub const FileError = error{ NotFound, PermissionDenied, ReadFailed };
pub const ReadError = FileError || error{TooLarge} || std.mem.Allocator.Error;

pub const File = struct {
    fd: c_int,

    pub fn openRead(path: [:0]const u8) FileError!File {
        const fd = open(path.ptr, O_RDONLY | O_CLOEXEC);
        if (fd < 0) return switch (errno()) {
            ENOENT, ESRCH => error.NotFound, // /proc/<pid> disappears when the process exits
            EACCES, EPERM => error.PermissionDenied,
            else => error.ReadFailed,
        };
        return .{ .fd = fd };
    }

    pub fn deinit(self: *File) void {
        _ = close(self.fd);
        self.* = undefined;
    }

    /// Reads up to `buf.len` bytes starting at `offset` and returns how many it got.
    /// Fewer than asked only happens at the end of the file.
    pub fn readAt(self: File, buf: []u8, offset: u64) FileError!usize {
        var done: usize = 0;
        while (done < buf.len) {
            const n = pread(self.fd, @ptrCast(buf[done..].ptr), buf.len - done, @intCast(offset + @as(u64, done)));
            if (n < 0) {
                if (errno() == EINTR) continue;
                return error.ReadFailed;
            }
            if (n == 0) break;
            done += @intCast(n);
        }
        return done;
    }
};

pub fn readFd(fd: c_int, buf: *anyopaque, count: usize) !isize {
    const n = read(fd, buf, count);
    if (n < 0) return error.ReadFailed;
    return n;
}

/// Reads a whole file into memory, for /proc and /sys files, whose size is not known in
/// advance. Fails with TooLarge instead of growing past `max_bytes`.
pub fn readFile(allocator: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ReadError![]u8 {
    var file = try File.openRead(path);
    defer file.deinit();

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try readFd(file.fd, &chunk, chunk.len);
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > max_bytes) return error.TooLarge;
        try list.appendSlice(allocator, chunk[0..len]);
    }
    return list.toOwnedSlice(allocator);
}

//------- testing helper ---
extern "c" fn fork() c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getpid() c_int;

pub fn currentPid() u32 {
    return @intCast(getpid());
}

pub fn spawnBurner(ms: u64) !u32 {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const until = timer.nowMs() + ms;
        var x: u64 = 0;
        while (timer.nowMs() < until) x +%= 1;
        std.mem.doNotOptimizeAway(x);
        _exit(0);
    }
    return @intCast(pid);
}

pub fn spawnSleeper() !u32 {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_]?[*:0]const u8{ "sleep", "30", null };
        _ = execv("/bin/sleep", &argv);
        _exit(127);
    }
    return @intCast(pid);
}

pub fn reap(pid: u32) void {
    _ = kill(@intCast(pid), 9); // SIGKILL; harmless if it already exited
    _ = waitpid(@intCast(pid), null, 0);
}

pub fn kill9(pid: u32) void {
    _ = kill(@intCast(pid), 9);
}

test "readFile reads /proc files and enforces the size limit" {
    const text = try readFile(std.testing.allocator, "/proc/self/maps", 4 * 1024 * 1024);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len > 0);

    try std.testing.expectError(error.TooLarge, readFile(std.testing.allocator, "/proc/self/maps", 10));
    try std.testing.expectError(error.NotFound, readFile(std.testing.allocator, "/proc/does-not-exist", 100));
}

test "File reads at an offset" {
    var file = try File.openRead("/proc/self/exe");
    defer file.deinit();

    var magic: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try file.readAt(&magic, 0));
    try std.testing.expectEqualStrings("\x7fELF", &magic);

    try std.testing.expectEqual(@as(usize, 3), try file.readAt(magic[0..3], 1));
    try std.testing.expectEqualStrings("ELF", magic[0..3]);
}
