//! Everything the build needs for the server, in one place.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    log: *std.Build.Module,
    agent: *std.Build.Module,
};

/// Builds the server and returns its module.
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

/// Runs the server's tests, and also installs the test binary as zig-out/bin/server-tests, so
/// the tests that need root can be run with sudo without building as root.
fn add_tests(b: *std.Build, module: *std.Build.Module, test_step: *std.Build.Step) void {
    // Tests inside server/** (root.zig and everything it @imports by file).
    const server_tests = b.addTest(.{ .root_module = module });
    // The e2e test profiles the test binary itself, and the agent only sends binaries that
    // have a GNU build ID: LLD writes one, as for the agent's tests.
    server_tests.build_id = .fast;
    server_tests.use_llvm = true;
    server_tests.use_lld = true;
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
    test_step.dependOn(&b.addInstallArtifact(server_tests, .{
        .dest_sub_path = "server-tests",
    }).step);
}
