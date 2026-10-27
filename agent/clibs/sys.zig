const std = @import("std");

extern "c" fn fork() c_int;
extern "c" fn getpid() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*]const ?[*:0]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

pub fn currentPid() u32 {
    return @intCast(std.c.getpid());
}

pub fn spawnSleeper() !u32 {
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_]?[*:0]const u8{ "sleep", "30", null };
        _ = execv("/bin/sleep", &argv);
        std.c._exit(127);
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
