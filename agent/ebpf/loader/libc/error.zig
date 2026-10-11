const std = @import("std");
const c = @import("clibs.zig").clibs;

// libbpf reports failure as a negative errno. We turn that into a Zig error in one place.
pub const Error = error{
    PermissionDenied, // no root / CAP_BPF, or blocked by the system
    InvalidArgument,
    OutOfMemory,
    NotFound,
    NotSupported, // the kernel lacks the feature
    Unexpected,
    VerifierRejected,
};

pub fn fromErrno(code: c_int) Error {
    return switch (code) {
        c.EPERM, c.EACCES => error.PermissionDenied,
        c.EINVAL => error.InvalidArgument,
        c.ENOMEM => error.OutOfMemory,
        c.ENOENT => error.NotFound,
        c.EOPNOTSUPP, c.ENOSYS => error.NotSupported,
        else => error.Unexpected,
    };
}
