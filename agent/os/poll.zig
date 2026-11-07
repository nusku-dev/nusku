//! Waits on a set of descriptors at once: the timers, the target and the cancel of a loop.
//! Each loop names its own sources with an enum, one descriptor per field.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

/// A poll over the descriptors named by `Source`, an enum with one field per descriptor.
pub fn Poll(comptime Source: type) type {
    if (@typeInfo(Source) != .@"enum") @compileError("Poll: `Source` must be an enum");

    return struct {
        fds: [source_count]linux.pollfd,

        const Self = @This();
        const source_count = @typeInfo(Source).@"enum".fields.len;

        /// The sources that were ready after one wait.
        pub const Ready = std.EnumSet(Source);

        /// A descriptor of -1 is never ready: poll(2) skips negative descriptors. Which sources
        /// must be there is the caller's to assert: only it knows which are optional.
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

        /// Waits until a source is ready, or `timeout_ms` passed (-1 waits for ever). A signal
        /// ends the wait early with nothing ready, which the caller treats like a timeout.
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
                // A descriptor closed while it is polled is a bug in the caller.
                assert(pollfd.revents & linux.POLL.NVAL == 0);
                // Anything reported counts as ready: an exited process's pidfd reports
                // POLLIN, and POLLHUP on newer kernels; timers and eventfds report POLLIN. An
                // error (POLLERR) also counts, so the caller's read fails loudly instead of
                // the loop spinning on a descriptor that is never readable.
                if (pollfd.revents != 0) ready.insert(@enumFromInt(index));
            }
            return ready;
        }
    };
}

// --- tests

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
