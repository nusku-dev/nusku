//! The part of libbpf the agent calls: the thin wrappers around the bpf(2) system call, and the
//! ring buffer reader. Everything else in the agent talks to the kernel through std.os.linux.

const std = @import("std");

pub const c = @cImport({
    @cInclude("errno.h");
    @cInclude("bpf/bpf.h");
    @cInclude("bpf/libbpf.h");
});

/// libbpf reports failure as a negative errno; this is the one place that turns it into an error.
pub const Error = error{
    /// Not root, or missing CAP_BPF / CAP_PERFMON, or blocked by the system.
    PermissionDenied,
    InvalidArgument,
    OutOfMemory,
    NotFound,
    /// The kernel lacks the feature.
    NotSupported,
    /// The verifier refused the program (the kernel says EACCES, which is not about permissions).
    VerifierRejected,
    Unexpected,
};

/// `code` is a positive errno value.
pub fn error_from_errno(code: c_int) Error {
    std.debug.assert(code > 0);
    return switch (code) {
        c.EPERM, c.EACCES => error.PermissionDenied,
        c.EINVAL => error.InvalidArgument,
        c.ENOMEM => error.OutOfMemory,
        c.ENOENT => error.NotFound,
        c.EOPNOTSUPP, c.ENOSYS => error.NotSupported,
        else => blk: {
            std.log.scoped(.bpf).warn("unexpected errno {d}", .{code});
            break :blk error.Unexpected;
        },
    };
}

/// The number of CPU slots the kernel may use, offline ones included. Per-CPU maps have one
/// value per slot, so their buffers must be this many values long.
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
