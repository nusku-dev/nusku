//! Everything the build needs for the server, in one place
const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
};

/// Builds the agent and returns its module.
pub fn add(b: *std.Build, options: Options) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("server/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    addTests(b, module, options.test_step);
    return module;
}

/// Runs the agent's tests, and also installs the test binary as zig-out/bin/agent-tests, so
/// the tests that need root can be run with sudo without building as root.
fn addTests(
    b: *std.Build,
    agent_module: *std.Build.Module,
    test_step: *std.Build.Step,
) void {

    // Tests inside server/** (root.zig and everything it @imports by file)
    const server_tests = b.addTest(.{ .root_module = agent_module });
    test_step.dependOn(&b.addRunArtifact(server_tests).step);
    test_step.dependOn(&b.addInstallArtifact(server_tests, .{
        .dest_sub_path = "server-tests",
    }).step);
}
