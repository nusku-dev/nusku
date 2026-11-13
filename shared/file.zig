//! Read-only file access with positional reads.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = std.c;

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("file.zig needs POSIX pread, which Windows does not have");
    }
    if (!builtin.link_libc) {
        @compileError("file.zig calls libc: add link_libc = true in build.zig");
    }
    if (@sizeOf(c.off_t) != 8) {
        @compileError("file.zig needs a 64-bit off_t");
    }
}

const path_bytes_max = 4096;
const interrupt_retries_max = 16;

pub const OpenError = error{ NotFound, PermissionDenied, ProcessNotFound, Unexpected };
pub const ReadError = error{ ProcessNotFound, InputOutput, Interrupted, Unexpected };

pub const File = struct {
    fd: c.fd_t,

    pub const Stat = struct {
        device_major: u32,
        device_minor: u32,
        inode: u64,
        size: u64,
        modified_s: i64,
        modified_ns: u32,
    };

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

    pub fn stat(file: *const File) ReadError!Stat {
        assert(file.fd >= 0);
        var found: std.os.linux.Statx = undefined;
        const mask = std.os.linux.STATX{
            .INO = true,
            .SIZE = true,
            .MTIME = true,
        };

        const result = std.os.linux.statx(file.fd, "", std.os.linux.AT.EMPTY_PATH, mask, &found);
        if (std.os.linux.errno(result) != .SUCCESS) return error.Unexpected;

        return .{
            .device_major = found.dev_major,
            .device_minor = found.dev_minor,
            .inode = found.ino,
            .size = found.size,
            .modified_s = found.mtime.sec,
            .modified_ns = found.mtime.nsec,
        };
    }

    pub fn size_bytes(file: *const File) ReadError!u64 {
        assert(file.fd >= 0);
        const result = c.lseek(file.fd, 0, c.SEEK.END);
        if (result >= 0) {
            return @intCast(result);
        }
        return read_error(errno());
    }

    pub fn read_at(file: *const File, buffer: []u8, offset: u64) ReadError!usize {
        assert(file.fd >= 0);
        assert(buffer.len > 0);
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
                if (result == 0) break;

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
    assert(code != .INTR);
    return switch (code) {
        .SRCH => error.ProcessNotFound,
        .IO => error.InputOutput,
        .BADF => unreachable,
        else => error.Unexpected,
    };
}
