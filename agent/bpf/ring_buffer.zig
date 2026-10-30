//! Reads a BPF ring buffer map with libbpf's reader. Records are handed to a callback, with the
//! callback's context typed at compile time, so a record can never reach the wrong function.

const std = @import("std");
const assert = std.debug.assert;
const libbpf = @import("libbpf.zig");

const c = libbpf.c;

pub const Error = error{ RingBufferCreateFailed, RingBufferConsumeFailed };

/// `on_record(context, bytes)` is called for every record, on the thread that calls `consume`.
/// `bytes` is valid only during the call: the space is given back to the kernel after it.
pub fn RingBuffer(comptime Context: type, comptime on_record: fn (*Context, []const u8) void) type {
    return struct {
        reader: *c.struct_ring_buffer,

        const Self = @This();

        /// `context` must stay at its address until `deinit`: libbpf keeps the pointer.
        pub fn init(map_fd: i32, context: *Context) Error!Self {
            assert(map_fd >= 0);
            const reader = c.ring_buffer__new(map_fd, record_callback, context, null) orelse
                return error.RingBufferCreateFailed;
            return .{ .reader = reader };
        }

        pub fn deinit(ring: *Self) void {
            c.ring_buffer__free(ring.reader);
            ring.* = undefined;
        }

        /// Reads every record in the ring now. Returns how many there were. The ring is bounded
        /// by its size, and the kernel cannot add records faster than they are read here for
        /// long, so this returns.
        pub fn consume(ring: *Self) Error!u32 {
            const result = c.ring_buffer__consume(ring.reader);
            if (result < 0) return error.RingBufferConsumeFailed;
            return @intCast(result);
        }

        fn record_callback(
            context: ?*anyopaque,
            data: ?*anyopaque,
            size: usize,
        ) callconv(.c) c_int {
            const typed: *Context = @ptrCast(@alignCast(context.?));
            const bytes: [*]const u8 = @ptrCast(data.?);
            on_record(typed, bytes[0..size]);
            // Never negative: that would stop libbpf from draining the ring.
            return 0;
        }
    };
}
