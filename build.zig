const std = @import("std");
const agent = @import("agent/build.zig");

pub fn build(b: *std.Build) void {
    // musl by default: it is what makes a fully static binary possible.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Created first so components can register their tests with it.
    const test_step = b.step("test", "Run all tests");

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const log_mod = b.createModule(.{
        .root_source_file = b.path("logger/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The agent: its libraries, kernel programs, module and tests all live in agent/build.zig.
    const agent_mod = agent.add(b, .{
        .target = target,
        .optimize = optimize,
        .test_step = test_step,
    });

    const exe = b.addExecutable(.{
        .name = "nusku",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("cli", cli_mod);
    exe.root_module.addImport("log", log_mod);
    exe.root_module.addImport("agent", agent_mod);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = cli_mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
