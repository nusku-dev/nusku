//! What /proc/stat says about the whole machine's CPU.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;

pub const Machine = struct {
    cpus: u32 = 0,
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,

    pub const states = .{ "user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal" };

    const buffer_bytes = 64 * 1024;

    pub fn read(machine: *Machine) !void {
        var file = try File.open("/proc/stat");
        defer file.deinit();
        var buffer: [buffer_bytes]u8 = undefined;
        const len = try file.read_at(&buffer, 0);
        machine.* = try parse(buffer[0..len], len == buffer.len);
    }

    fn parse(text: []const u8, cut: bool) error{Malformed}!Machine {
        var machine = Machine{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        const first = lines.next() orelse return error.Malformed;
        var fields = std.mem.tokenizeScalar(u8, first, ' ');
        const name = fields.next() orelse return error.Malformed;
        if (!std.mem.eql(u8, name, "cpu")) return error.Malformed;
        inline for (states) |state| {
            if (fields.next()) |value| @field(machine, state) = try number_parse(value);
        }

        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "cpu")) {
                if (machine.cpus == 0) return error.Malformed;
                return machine;
            }
            machine.cpus += 1;
        }
        if (cut or machine.cpus == 0) return error.Malformed;
        return machine;
    }

    pub fn since(machine: *const Machine, before: *const Machine) Machine {
        var delta = Machine{ .cpus = machine.cpus };
        inline for (states) |state| {
            @field(delta, state) = @field(machine, state) -| @field(before, state);
        }
        return delta;
    }

    pub fn total(machine: *const Machine) u64 {
        return machine.user + machine.nice + machine.system + machine.idle + machine.iowait +
            machine.irq + machine.softirq + machine.steal;
    }

    fn number_parse(value: []const u8) error{Malformed}!u64 {
        return std.fmt.parseInt(u64, value, 10) catch error.Malformed;
    }
};

const testing = std.testing;

test "the machine line is read with its CPUs" {
    const text =
        \\cpu  100 2 30 400 5 0 6 7 0 0
        \\cpu0 50 1 15 200 2 0 3 3 0 0
        \\cpu1 50 1 15 200 3 0 3 4 0 0
        \\intr 12345 0 0
        \\
    ;
    const machine = try Machine.parse(text, false);
    try testing.expectEqual(@as(u32, 2), machine.cpus);
    try testing.expectEqual(@as(u64, 100), machine.user);
    try testing.expectEqual(@as(u64, 400), machine.idle);
    try testing.expectEqual(@as(u64, 7), machine.steal);
    try testing.expectEqual(@as(u64, 550), machine.total());
}

test "since: what each state got, and a counter that went back is 0" {
    const before = Machine{ .cpus = 2, .user = 10, .idle = 50, .iowait = 9 };
    const now = Machine{ .cpus = 2, .user = 30, .idle = 120, .iowait = 7 };
    const delta = now.since(&before);
    try testing.expectEqual(@as(u64, 20), delta.user);
    try testing.expectEqual(@as(u64, 70), delta.idle);
    try testing.expectEqual(@as(u64, 0), delta.iowait);
    try testing.expectEqual(@as(u64, 90), delta.total());
}

test "a cut or strange file is refused" {
    try testing.expectError(error.Malformed, Machine.parse("cpu  1 2 3 4\ncpu0 1 2 3 4", true));
    try testing.expectError(error.Malformed, Machine.parse("intr 1 2\n", false));
    try testing.expectError(error.Malformed, Machine.parse("cpu  1 x 3 4\ncpu0 1\nintr\n", false));
    try testing.expectError(error.Malformed, Machine.parse("cpu  1 2 3 4\nintr 1\n", false));
}

test "this machine's /proc/stat" {
    var machine: Machine = undefined;
    try machine.read();
    try testing.expect(machine.cpus >= 1);
    try testing.expect(machine.idle + machine.user + machine.system > 0);
}
