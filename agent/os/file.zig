//! Read-only file access with positional reads. Every read goes through pread, so the
//! file position never matters and reads from different places can't interfere.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = std.c;

comptime {
    // pread and errno come from a POSIX libc.
    if (builtin.os.tag == .windows) {
        @compileError("file.zig needs POSIX pread, which Windows does not have");
    }
    if (!builtin.link_libc) {
        @compileError("file.zig calls libc: add link_libc = true in build.zig");
    }
    // Offsets into /proc/<pid>/mem are 64-bit addresses, so a 32-bit off_t cannot reach them.
    if (@sizeOf(c.off_t) != 8) {
        @compileError("file.zig needs a 64-bit off_t");
    }
}

/// PATH_MAX on Linux, including the terminating zero.
const path_bytes_max = 4096;
/// A signal storm should not keep a read spinning forever.
const interrupt_retries_max = 16;

pub const OpenError = error{ NotFound, PermissionDenied, ProcessNotFound, Unexpected };
pub const ReadError = error{ ProcessNotFound, InputOutput, Interrupted, Unexpected };

pub const File = struct {
    fd: c.fd_t,

    pub fn open(path: [:0]const u8) OpenError!File {
        assert(path.len > 0);
        assert(path.len < path_bytes_max);

        const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd >= 0) return File{ .fd = fd };

        const code = errno();
        return switch (code) {
            .NOENT => error.NotFound,
            .ACCES, .PERM => error.PermissionDenied,
            .SRCH => error.ProcessNotFound,
            else => error.Unexpected,
        };
    }

    pub fn deinit(file: *File) void {
        assert(file.fd >= 0);
        const result = c.close(file.fd);
        if (result != 0) assert(errno() != .BADF);
        file.* = undefined;
    }

    /// Size in bytes. Files under /proc report 0. This moves the file position, which is
    /// fine because every read in this file is positional.
    pub fn size_bytes(file: *const File) ReadError!u64 {
        assert(file.fd >= 0);
        const result = c.lseek(file.fd, 0, c.SEEK.END);
        if (result >= 0) {
            return @intCast(result);
        }
        return read_error(errno());
    }

    /// Reads at `offset` until `buffer` is full or the file ends. Returns the part of
    /// `buffer` that was filled, which is shorter than `buffer` only at end of file.
    pub fn read_at(file: *const File, buffer: []u8, offset: u64) ReadError!usize {
        assert(file.fd >= 0);
        assert(buffer.len > 0);
        // pread takes a signed offset, so the whole range must fit in an off_t.
        assert(offset <= std.math.maxInt(c.off_t) - buffer.len);

        var read_total: usize = 0;
        var interrupts: u32 = 0;
        while (read_total < buffer.len) {
            const result = c.pread(
                file.fd,
                buffer[read_total..].ptr,
                buffer.len - read_total,
                @intCast(offset + read_total),
            );
            if (result > 0) {
                read_total += @intCast(result);
            } else {
                if (result == 0) break; // End of file.

                const code = errno();
                if (code == .INTR) {
                    interrupts += 1;
                    if (interrupts < interrupt_retries_max) continue;
                    return error.Interrupted;
                }
                return read_error(code);
            }
        }

        assert(read_total <= buffer.len);
        return read_total;
    }

    pub fn read(file: *const File, buffer: []u8) ReadError!usize {
        assert(file.fd >= 0);
        assert(buffer.len > 0);

        const result = c.read(file.fd, buffer.ptr, buffer.len);
        if (result < 0) return read_error(errno());
        return @intCast(result);
    }
};

fn errno() c.E {
    return @enumFromInt(c._errno().*);
}

fn read_error(code: c.E) ReadError {
    assert(code != .INTR); // Callers retry EINTR themselves.
    return switch (code) {
        .SRCH => error.ProcessNotFound,
        // For /proc/<pid>/mem on Linux this means the address is not mapped in the target.
        .IO => error.InputOutput,
        // The fd was closed or never opened: a bug in our code, not an operating error.
        .BADF => unreachable,
        else => blk: {
            std.log.warn("file read: errno {d}", .{@intFromEnum(code)});
            break :blk error.Unexpected;
        },
    };
}
