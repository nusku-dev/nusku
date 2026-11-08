//! The processes of the machine as /proc gives them, in the kernel's own units. Nothing here
//! keeps state between looks or turns ticks into percent: the layer above does that.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;
const Directory = @import("../os.zig").directory.Directory;
const process = @import("../os.zig").process;
const timer = @import("../os.zig").timer;
const Stat = @import("stat.zig").Stat;
const Statm = @import("statm.zig").Statm;
const Status = @import("status.zig").Status;
const Users = @import("users.zig").Users;
const CmdLine = @import("cmdline.zig").CmdLine;

pub const Entry = struct {
    stat: Stat,
    /// When `stat` was read, on the monotonic clock. A look takes a while, and a process's CPU
    /// is measured between its own two reads, not between the starts of two looks.
    read_ns: u64,
    statm: Statm,
    status: Status,
    cmdline: CmdLine,
    user: []const u8,
};

pub const Proc = struct {
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    /// The names that `Entry.user` points into: kept as long as the entries are.
    users: Users = .{},

    /// Every process now, keyed by pid. Allocates only when there are more processes than the
    /// map has room for.
    pub fn read(proc: *Proc, gpa: std.mem.Allocator) !void {
        proc.entries.clearRetainingCapacity();

        var dir = try Directory.open("/proc");
        defer dir.deinit();

        // Read again each look, for users added since. The old names go only now: the
        // entries that pointed into them were just cleared.
        var users: Users = .{};
        try users.load(gpa);
        proc.users.deinit(gpa);
        proc.users = users;

        while (try dir.next()) |name| {
            const pid = pid_parse(name) orelse continue; // ".", "self", "meminfo", ...

            var stat: Stat = undefined;
            stat.read(pid) catch |err| switch (err) {
                error.ProcessNotFound => continue, // Ended while we walked.
                else => return err,
            };
            const read_ns = timer.monotonic_ns();

            var statm: Statm = undefined;
            statm.read(pid) catch |err| switch (err) {
                error.ProcessNotFound => continue, // Ended while we walked.
                else => return err,
            };

            var status: Status = undefined;
            status.read(pid) catch |err| switch (err) {
                error.ProcessNotFound => continue, // Ended while we walked.
                else => return err,
            };

            var cmdline: CmdLine = undefined;
            cmdline.read(pid) catch |err| switch (err) {
                error.ProcessNotFound => continue, // Ended while we walked.
                else => return err,
            };

            const user = proc.users.get(status.uid);

            try proc.entries.put(gpa, pid, .{
                .stat = stat,
                .read_ns = read_ns,
                .statm = statm,
                .status = status,
                .user = user,
                .cmdline = cmdline,
            });
        }
    }

    pub fn deinit(proc: *Proc, gpa: std.mem.Allocator) void {
        proc.entries.deinit(gpa);
        proc.users.deinit(gpa);
        proc.* = undefined;
    }

    /// The same process in this read: same pid and same start, so not a pid the kernel gave
    /// again to a new process. Null when it is not here.
    pub fn same(proc: *const Proc, stat: *const Stat) ?*const Entry {
        const entry = proc.entries.getPtr(stat.pid) orelse return null;
        if (entry.stat.start_ticks != stat.start_ticks) return null; // The pid was reused.
        return entry;
    }
};
fn pid_parse(name: []const u8) ?u32 {
    // parseInt would take "+1": a pid starts with a digit.
    if (name.len == 0 or !std.ascii.isDigit(name[0])) return null;
    const pid = std.fmt.parseInt(u32, name, 10) catch return null;
    return if (process.pid_valid(pid)) pid else null;
}

const testing = std.testing;

test "a read of /proc finds this process, and a second read reuses the memory" {
    var proc: Proc = .{};
    defer proc.deinit(testing.allocator);

    try proc.read(testing.allocator);
    const own = proc.entries.get(process.current_pid()) orelse return error.OwnProcessMissing;
    try testing.expect(own.stat.name().len > 0);

    try proc.read(testing.allocator);
    try std.testing.expect(proc.entries.get(process.current_pid()) != null);
}

test "every entry is filed under its own pid, and this process is whole" {
    var proc: Proc = .{};
    defer proc.deinit(testing.allocator);
    try proc.read(testing.allocator);

    try testing.expect(proc.entries.count() >= 2); // This test and the build runner.
    var entries = proc.entries.iterator();
    while (entries.next()) |entry| {
        try testing.expectEqual(entry.key_ptr.*, entry.value_ptr.stat.pid);
    }

    const own = proc.entries.get(process.current_pid()).?;
    try testing.expectEqual(std.os.linux.geteuid(), own.status.uid);
    try testing.expect(own.status.rss_kb > 0);
}
