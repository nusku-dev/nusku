const std = @import("std");
const c = @import("clibs.zig").clibs;
const err = @import("error.zig");

const Error = err.Error;
const fromErrno = err.fromErrno;

pub const Program = struct {
    fd: c_int,

    const Kind = enum { perf_event };

    /// Loads a program into the kernel; the verifier runs here. `insns` is a whole number of
    /// 8-byte instructions. `license` is the license section including its terminating zero.
    /// If the load fails, `log` holds the verifier's explanation as a zero-terminated string.
    pub fn load(kind: Kind, name: [:0]const u8, insns: []align(8) const u8, license: []const u8, log: []u8) Error!Program {
        std.debug.assert(insns.len > 0 and insns.len % 8 == 0);
        std.debug.assert(license.len > 0 and license[license.len - 1] == 0);

        const prog_type: c_uint = switch (kind) {
            .perf_event => c.BPF_PROG_TYPE_PERF_EVENT,
        };
        const code: *const c.struct_bpf_insn = @ptrCast(insns.ptr);
        const count = insns.len / 8;

        var opts = ProgLoadOpts{};
        opts.sz = @sizeOf(ProgLoadOpts);
        // libbpf's type for this is opaque to Zig; it is the same memory.
        const opts_ptr: *c.struct_bpf_prog_load_opts = @ptrCast(&opts);

        // First attempt without a log: a log buffer that is too small makes the kernel fail the load.
        var fd = c.bpf_prog_load(prog_type, name.ptr, license.ptr, code, count, opts_ptr);

        if (fd >= 0) return .{ .fd = fd };
        const failure = -fd;

        // It failed: load again at log level 1 so the verifier explains itself.
        if (log.len > 0) {
            log[0] = 0;
            opts.log_buf = log.ptr;
            opts.log_size = @intCast(log.len);
            opts.log_level = 1;
            fd = c.bpf_prog_load(prog_type, name.ptr, license.ptr, code, count, opts_ptr);
            if (fd >= 0) return .{ .fd = fd };
        }

        // The verifier reports a rejected program as EACCES, which is not a permissions problem.
        if (failure == c.EACCES) return error.VerifierRejected;
        return fromErrno(failure);
    }

    pub fn deinit(self: *Program) void {
        _ = c.close(self.fd);
        self.* = undefined;
    }
};

/// Mirror of libbpf 1.5.0's `struct bpf_prog_load_opts`. Zig's C import turns that struct
/// into an opaque type (it ends in a zero-width bit-field), so we declare our own.
/// libbpf checks `sz`, so fields we leave at zero are ignored. If libbpf is upgraded,
/// compare this with the struct in bpf.h again.
const ProgLoadOpts = extern struct {
    sz: usize = 0,
    attempts: c_int = 0,
    expected_attach_type: c_uint = 0,
    prog_btf_fd: u32 = 0,
    prog_flags: u32 = 0,
    prog_ifindex: u32 = 0,
    kern_version: u32 = 0,
    attach_btf_id: u32 = 0,
    attach_prog_fd: u32 = 0,
    attach_btf_obj_fd: u32 = 0,
    fd_array: ?[*]const c_int = null,
    func_info: ?*const anyopaque = null,
    func_info_cnt: u32 = 0,
    func_info_rec_size: u32 = 0,
    line_info: ?*const anyopaque = null,
    line_info_cnt: u32 = 0,
    line_info_rec_size: u32 = 0,
    log_level: u32 = 0,
    log_size: u32 = 0,
    log_buf: ?[*]u8 = null,
    log_true_size: u32 = 0,
    token_fd: u32 = 0,
};

const testing = std.testing;

test "loads a minimal perf_event program" {
    // BPF instructions:
    //   r0 = 0
    //   exit
    const insns: [16]u8 align(8) = .{
        0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    const license = "GPL\x00";
    var log = [_]u8{0} ** 4096;

    var program = Program.load(
        .perf_event,
        "nusku_test",
        &insns,
        license,
        &log,
    ) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };
    defer program.deinit();

    try testing.expect(program.fd >= 0);
}

test "rejected program includes verifier diagnostics" {

    // The stack slot has not been initialized. The verifier should
    // reject this read on kernels supporting this program type.
    const insns: [24]u8 align(8) = .{
        // r0 = 0
        0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

        // r0 = *(u64 *)(r0 + 0)
        // Invalid: r0 contains a scalar zero, not a valid memory pointer.
        0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

        // exit
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const license = "GPL\x00";
    var log = [_]u8{0} ** (64 * 1024);

    if (Program.load(
        .perf_event,
        "nusku_bad",
        &insns,
        license,
        &log,
    )) |program| {
        var loaded = program;
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        try testing.expect(erro == error.VerifierRejected);
    }

    try testing.expect(std.mem.sliceTo(&log, 0).len > 0);
}

test "rejected program returns an error with an empty log buffer" {
    // Same invalid uninitialized-stack read as above.
    const insns: [24]u8 align(8) = .{
        // r0 = 0
        0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

        // r0 = *(u64 *)(r0 + 0)
        // Invalid: r0 contains a scalar zero, not a valid memory pointer.
        0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

        // exit
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    const license = "GPL\x00";
    var log: [0]u8 = .{};

    if (Program.load(
        .perf_event,
        "nusku_bad",
        &insns,
        license,
        &log,
    )) |program| {
        var loaded = program;
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        try testing.expect(erro == error.VerifierRejected);
    }
}

test "deinit closes the program file descriptor" {
    const insns: [16]u8 align(8) = .{
        0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    const license = "GPL\x00";
    var log = [_]u8{0} ** 4096;

    var program = Program.load(
        .perf_event,
        "nusku_test",
        &insns,
        license,
        &log,
    ) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };

    const fd = program.fd;
    program.deinit();

    // F_GETFD returns -1 for a closed descriptor.
    try testing.expectEqual(@as(c_int, -1), c.fcntl(fd, c.F_GETFD));
}
