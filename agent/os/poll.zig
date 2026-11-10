//! Waits on a set of descriptors at once.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

pub fn Poll(comptime Source: type) type {
    if (@typeInfo(Source) != .@"enum") @compileError("Poll: `Source` must be an enum");

    return struct {
        fds: [source_count]linux.pollfd,

        const Self = @This();
        const source_count = @typeInfo(Source).@"enum".fields.len;

        pub const Ready = std.EnumSet(Source);

        pub fn init(fds: std.EnumArray(Source, i32)) Self {
            var poll: Self = undefined;
            for (&poll.fds, 0..) |*pollfd, index| {
                const source: Source = @enumFromInt(index);
                const fd = fds.get(source);
                assert(fd >= -1);
                pollfd.* = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            }
            return poll;
        }

        pub fn wait(poll: *Self, timeout_ms: i32) error{Unexpected}!Ready {
            assert(timeout_ms >= -1);
            const result = linux.poll(&poll.fds, poll.fds.len, timeout_ms);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => return .initEmpty(),
                else => return error.Unexpected,
            }
            assert(result <= poll.fds.len);

            var ready: Ready = .initEmpty();
            for (poll.fds, 0..) |pollfd, index| {
                assert(pollfd.revents & linux.POLL.NVAL == 0);
                if (pollfd.revents != 0) ready.insert(@enumFromInt(index));
            }
            return ready;
        }
    };
}

const testing = std.testing;

test "only the sources with something to read are ready, and -1 never is" {
    const Source = enum { written, idle, absent };
    const TestPoll = Poll(Source);

    const written = try eventfd_open();
    defer _ = linux.close(written);
    const idle = try eventfd_open();
    defer _ = linux.close(idle);

    const one: u64 = 1;
    const wrote = linux.write(written, std.mem.asBytes(&one), @sizeOf(u64));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));

    var poll = TestPoll.init(.init(.{ .written = written, .idle = idle, .absent = -1 }));
    const ready = try poll.wait(0);
    try testing.expect(ready.contains(.written));
    try testing.expect(!ready.contains(.idle));
    try testing.expect(!ready.contains(.absent));
}

test "a wait with nothing ready ends at its timeout, empty" {
    const Source = enum { idle };
    const idle = try eventfd_open();
    defer _ = linux.close(idle);

    var poll = Poll(Source).init(.init(.{ .idle = idle }));
    const ready = try poll.wait(10);
    try testing.expectEqual(@as(usize, 0), ready.count());
}

fn eventfd_open() !i32 {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.Unexpected;
    return @intCast(result);
}
