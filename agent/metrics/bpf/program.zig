//! A BPF program loaded into the kernel.

const std = @import("std");
const assert = std.debug.assert;
const libbpf = @import("libbpf.zig");

const c = libbpf.c;
const Error = libbpf.Error;
const error_from_errno = libbpf.error_from_errno;

pub const instruction_size = 8;

pub const Program = struct {
    fd: i32,

    pub const Kind = enum { perf_event };

    pub const Options = struct {
        kind: Kind,
        name: [:0]const u8,
        instructions: []align(8) const u8,
        license: []const u8,
        /// Receives the verifier's explanation, zero-terminated, if the program is refused.
        log: []u8,
    };

    pub fn load(options: Options) Error!Program {
        assert(options.name.len > 0);
        assert(options.instructions.len > 0);
        assert(options.instructions.len % instruction_size == 0);
        assert(options.license.len > 0);
        assert(options.license[options.license.len - 1] == 0);

        const program_type: c_uint = switch (options.kind) {
            .perf_event => c.BPF_PROG_TYPE_PERF_EVENT,
        };
        const instructions: *const c.struct_bpf_insn = @ptrCast(options.instructions.ptr);
        const instruction_count = options.instructions.len / instruction_size;

        var load_options = LoadOptions{ .sz = @sizeOf(LoadOptions) };
        const load_options_c: *c.struct_bpf_prog_load_opts = @ptrCast(&load_options);

        var fd = c.bpf_prog_load(
            program_type,
            options.name.ptr,
            options.license.ptr,
            instructions,
            instruction_count,
            load_options_c,
        );
        if (fd >= 0) return .{ .fd = fd };
        const failure = -fd;

        // It failed: load again at log level 1, so the verifier explains itself.
        if (options.log.len > 0) {
            options.log[0] = 0;
            load_options.log_buf = options.log.ptr;
            load_options.log_size = @intCast(@min(options.log.len, std.math.maxInt(u32)));
            load_options.log_level = 1;
            fd = c.bpf_prog_load(
                program_type,
                options.name.ptr,
                options.license.ptr,
                instructions,
                instruction_count,
                load_options_c,
            );
            if (fd >= 0) return .{ .fd = fd };
        }

        // The verifier reports a refused program as EACCES, which is not about permissions.
        if (failure == c.EACCES) return error.VerifierRejected;
        return error_from_errno(failure);
    }

    pub fn deinit(program: *Program) void {
        assert(program.fd >= 0);
        _ = std.os.linux.close(program.fd);
        program.* = undefined;
    }
};

const LoadOptions = extern struct {
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

comptime {
    assert(@sizeOf(LoadOptions) == 112);
    assert(@offsetOf(LoadOptions, "fd_array") == 48);
    assert(@offsetOf(LoadOptions, "log_level") == 88);
    assert(@offsetOf(LoadOptions, "log_buf") == 96);
    assert(@offsetOf(LoadOptions, "token_fd") == 108);
}

const testing = std.testing;
const license_testing = "GPL\x00";

const instructions_valid: [16]u8 align(8) = .{
    0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// The read goes through a scalar, not a pointer, so the verifier must refuse it.
const instructions_invalid: [24]u8 align(8) = .{
    0xb7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x95, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "a minimal perf_event program loads, and deinit closes it (needs root, skipped otherwise)" {
    var log: [4096]u8 = undefined;
    var program = Program.load(.{
        .kind = .perf_event,
        .name = "nusku_test",
        .instructions = &instructions_valid,
        .license = license_testing,
        .log = &log,
    }) catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    const fd = program.fd;
    try testing.expect(fd >= 0);
    program.deinit();

    const result = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    try testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(result));
}

test "a refused program comes with the verifier's explanation, or none without a log" {
    var log: [64 * 1024]u8 = undefined;
    const logs = [_][]u8{ &log, log[0..0] };
    for (logs) |log_buffer| {
        if (Program.load(.{
            .kind = .perf_event,
            .name = "nusku_bad",
            .instructions = &instructions_invalid,
            .license = license_testing,
            .log = log_buffer,
        })) |loaded| {
            var program = loaded;
            program.deinit();
            return error.TestUnexpectedResult;
        } else |err| switch (err) {
            error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
            error.VerifierRejected => {},
            else => return err,
        }
        if (log_buffer.len > 0) try testing.expect(std.mem.sliceTo(log_buffer, 0).len > 0);
    }
}
