//! Starting a program to profile: it is held before its first instruction, so profiling misses
//! nothing of it.

const std = @import("std");
const linux = std.os.linux;

const assert = std.debug.assert;

pub const Error = error{
    OutOfMemory,
    ProgramNotFound,
    NotExecutable,
    TooManyArguments,
    ExitedAtOnce,
    LaunchFailed,
};

const path_bytes_max = 4096;
const args_max = 4096;
const arg_bytes_max = 128 * 1024;
const signals_max = 64;
/// The kernel's CLOSE_RANGE_CLOEXEC: std's CLOSE_RANGE struct has its bits one place off.
const close_range_cloexec = 1 << 2;

/// Held stopped: `release` lets it run. It reads nothing, writes nowhere, and holds none of
/// this process's files. Its parent must reap it.
pub fn launch(arena: std.mem.Allocator, argv: []const []const u8) Error!u32 {
    assert(argv.len > 0);
    if (argv.len > args_max) return error.TooManyArguments;
    for (argv) |arg| if (arg.len > arg_bytes_max) return error.TooManyArguments;
    if (argv[0].len == 0 or argv[0].len >= path_bytes_max) return error.ProgramNotFound;
    const path = try path_find(arena, argv[0]);
    const args = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, args) |arg, *out| out.* = try arena.dupeZ(u8, arg);

    var pipe: [2]i32 = undefined;
    const piped = linux.pipe2(&pipe, .{ .CLOEXEC = true });
    if (linux.errno(piped) != .SUCCESS) return error.LaunchFailed;
    const pid = std.c.fork();
    if (pid < 0) {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
        return error.LaunchFailed;
    }
    if (pid == 0) child_run(path, args, pipe[1]);
    _ = linux.close(pipe[1]);
    defer _ = linux.close(pipe[0]);

    var code: i32 = 0;
    const got = linux.read(pipe[0], @ptrCast(&code), @sizeOf(i32));
    if (got == @sizeOf(i32)) {
        reap(@intCast(pid));
        return switch (@as(linux.E, @enumFromInt(code))) {
            .NOENT, .NOTDIR => error.ProgramNotFound,
            .ACCES, .NOEXEC, .PERM => error.NotExecutable,
            else => error.LaunchFailed,
        };
    }
    return stop(@intCast(pid));
}

/// After fork: only calls that are safe there, then the program or an exit.
fn child_run(path: [*:0]const u8, args: [*:null]const ?[*:0]const u8, report: i32) noreturn {
    _ = linux.setsid();
    // A signal this process ignores would stay ignored across execve: SIGPIPE, for one.
    const default = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    var signal: u32 = 1;
    while (signal <= signals_max) : (signal += 1) {
        const which: linux.SIG = @enumFromInt(signal);
        if (which == .KILL or which == .STOP) continue;
        _ = linux.sigaction(which, &default, null);
    }
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(null_fd) == .SUCCESS) {
        const fd: i32 = @intCast(null_fd);
        for ([_]i32{ 0, 1, 2 }) |target| _ = linux.dup2(fd, target);
        if (fd > 2) _ = linux.close(fd);
    }
    // The profiler's own files (BPF maps, sockets, perf events) must not reach the program.
    // Closed on exec rather than now, so a failed exec can still report through the pipe.
    _ = linux.syscall3(.close_range, 3, std.math.maxInt(u32), close_range_cloexec);
    const result = linux.execve(path, args, @ptrCast(std.c.environ));
    const code: i32 = @intFromEnum(linux.errno(result));
    _ = linux.write(report, @ptrCast(&code), @sizeOf(i32));
    linux.exit(127);
}

fn stop(pid: u32) Error!u32 {
    _ = linux.kill(@intCast(pid), .STOP);
    var status: u32 = 0;
    while (true) {
        const result = linux.waitpid(@intCast(pid), &status, linux.W.UNTRACED);
        switch (linux.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.LaunchFailed,
        }
    }
    if (linux.W.IFSTOPPED(status)) return pid;
    return error.ExitedAtOnce;
}

/// Lets a program it holds run.
pub fn release(pid: u32) void {
    _ = linux.kill(@intCast(pid), .CONT);
}

/// Ends a program it started: it may be stopped, and a stopped one acts on nothing but SIGKILL.
pub fn end(pid: u32) void {
    _ = linux.kill(@intCast(pid), .CONT);
    _ = linux.kill(@intCast(pid), .TERM);
}

/// Kills a program it holds that never ran, and reaps it.
pub fn discard(pid: u32) void {
    _ = linux.kill(@intCast(pid), .KILL);
    reap(pid);
}

/// Collects a program it started once it has ended; false while it still runs.
pub fn reaped(pid: u32) bool {
    var status: u32 = 0;
    const result = linux.waitpid(@intCast(pid), &status, linux.W.NOHANG);
    return switch (linux.errno(result)) {
        .SUCCESS => result != 0,
        .CHILD => true,
        else => false,
    };
}

fn reap(pid: u32) void {
    var status: u32 = 0;
    while (linux.errno(linux.waitpid(@intCast(pid), &status, 0)) == .INTR) {}
}

fn path_find(arena: std.mem.Allocator, name: []const u8) Error![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return (try arena.dupeZ(u8, name)).ptr;
    const search = std.c.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.tokenizeScalar(u8, std.mem.span(search), ':');
    while (dirs.next()) |dir| {
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
        if (linux.errno(linux.access(full, linux.X_OK)) == .SUCCESS) return full.ptr;
    }
    return error.ProgramNotFound;
}

const testing = std.testing;

test "a program starts stopped, and ends when asked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = try launch(arena.allocator(), &.{ "sleep", "30" });
    try testing.expectEqual('T', state_of(pid));
    try testing.expect(!reaped(pid));
    end(pid);
    try reaped_wait(pid);
}

test "a missing program, or one that ends at once, is an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.ProgramNotFound, launch(a, &.{"no-such-program-nusku"}));
    try testing.expectError(error.ProgramNotFound, launch(a, &.{"/no/such/program"}));
    try testing.expectError(error.NotExecutable, launch(a, &.{"/etc/hostname"}));
    const many = try a.alloc([]const u8, args_max + 1);
    @memset(many, "sleep");
    try testing.expectError(error.TooManyArguments, launch(a, many));
}

test "a released program runs, holding none of this process's files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const own = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    try testing.expect(linux.errno(own) == .SUCCESS);
    defer _ = linux.close(@intCast(own));

    const pid = try launch(arena.allocator(), &.{ "sleep", "30" });
    defer {
        end(pid);
        reaped_wait(pid) catch {};
    }
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/fd/{d}", .{ pid, own });
    var link: [64]u8 = undefined;
    try testing.expect(linux.errno(linux.readlink(path, &link, link.len)) == .NOENT);

    release(pid);
    var waited: u32 = 0;
    while (state_of(pid) == 'T') : (waited += 1) {
        if (waited > 200) return error.NotReleased;
        pause_ms(10);
    }
    try testing.expect(!reaped(pid));
}

fn reaped_wait(pid: u32) !void {
    var waited: u32 = 0;
    while (!reaped(pid)) : (waited += 1) {
        if (waited > 200) return error.NotEnded;
        pause_ms(10);
    }
}

fn pause_ms(ms: u64) void {
    const pause = linux.timespec{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&pause, null);
}

fn state_of(pid: u32) u8 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return 0;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return 0;
    defer _ = linux.close(@intCast(fd));
    var buffer: [256]u8 = undefined;
    const got = linux.read(@intCast(fd), &buffer, buffer.len);
    if (linux.errno(got) != .SUCCESS) return 0;
    const text = buffer[0..got];
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return 0;
    return if (close + 2 < text.len) text[close + 2] else 0;
}
