//! The part of libbpf the agent calls.

const std = @import("std");
const log = @import("../../log.zig").agent;

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("bpf/bpf.h");
    @cInclude("bpf/libbpf.h");
});

pub const Error = error{
    /// Not root, or missing CAP_BPF / CAP_PERFMON, or blocked by the system.
    PermissionDenied,
    InvalidArgument,
    OutOfMemory,
    NotFound,
    NotSupported,
    /// The verifier refused the program (the kernel says EACCES, which is not about permissions).
    VerifierRejected,
    Unexpected,
};

pub fn error_from_errno(code: c_int) Error {
    std.debug.assert(code > 0);
    return switch (code) {
        c.EPERM, c.EACCES => error.PermissionDenied,
        c.EINVAL => error.InvalidArgument,
        c.ENOMEM => error.OutOfMemory,
        c.ENOENT => error.NotFound,
        c.EOPNOTSUPP, c.ENOSYS => error.NotSupported,
        else => blk: {
            log.warn("unexpected error from a bpf system call", .{ .errno = code });
            break :blk error.Unexpected;
        },
    };
}

pub fn cpu_possible_count() Error!u32 {
    const count = c.libbpf_num_possible_cpus();
    if (count < 0) return error_from_errno(-count);
    std.debug.assert(count > 0);
    return @intCast(count);
}

test "every errno maps to an error, and EACCES is about permissions here" {
    try std.testing.expectEqual(error.PermissionDenied, error_from_errno(c.EACCES));
    try std.testing.expectEqual(error.NotFound, error_from_errno(c.ENOENT));
    try std.testing.expectEqual(error.OutOfMemory, error_from_errno(c.ENOMEM));
}

test "this machine has at least one CPU" {
    try std.testing.expect(try cpu_possible_count() >= 1);
}
