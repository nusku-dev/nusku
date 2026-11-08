//! The server's module and tests.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    log: *std.Build.Module,
    agent: *std.Build.Module,
};

pub fn add(b: *std.Build, options: Options) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("server/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    module.addImport("log", options.log);
    module.addImport("agent", options.agent);

    add_tests(b, module, options.test_step);
    return module;
}

/// Also installs zig-out/bin/server-tests, to run the root tests with sudo.
fn add_tests(b: *std.Build, module: *std.Build.Module, test_step: *std.Build.Step) void {
    const server_tests = b.addTest(.{ .root_module = module });
    // The e2e test profiles this binary, and the agent sends only binaries with a build ID.
    server_tests.build_id = .fast;
    server_tests.use_llvm = true;
    server_tests.use_lld = true;
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
    test_step.dependOn(&b.addInstallArtifact(server_tests, .{
        .dest_sub_path = "server-tests",
    }).step);
}
