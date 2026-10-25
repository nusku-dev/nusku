const std = @import("std");
const c = @import("import.zig").clibs;

const assert = std.debug.assert;

pub const Error = error{ RingBufferCreateFailed, RingBufferConsumeFailed };
pub const RecordCallback = *const fn (context: ?*anyopaque, data: ?*anyopaque, size: usize) callconv(.c) c_int;

pub const cRingBuf = struct {
    reader: *c.struct_ring_buffer,

    pub fn init(map_fd: c_int, onRecord: RecordCallback, ctx: ?*anyopaque) !cRingBuf {
        assert(map_fd >= 0);

        const reader = c.ring_buffer__new(map_fd, onRecord, ctx, null) orelse {
            return Error.RingBufferCreateFailed;
        };

        errdefer c.ring_buffer__free(reader);
        return .{ .reader = reader };
    }

    /// Reads everything currently in the ring. Returns how many records it read.
    pub fn consume(self: *cRingBuf) !u32 {
        const rc = c.ring_buffer__consume(self.reader);
        if (rc < 0) return Error.RingBufferConsumeFailed;
        return @intCast(rc);
    }

    pub fn deinit(self: *cRingBuf) void {
        c.ring_buffer__free(self.reader);
        self.* = undefined;
    }
};
