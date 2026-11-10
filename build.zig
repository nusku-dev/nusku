const std = @import("std");
const agent = @import("agent/build.zig");
const server = @import("server/build.zig");

pub fn build(b: *std.Build) void {
    // musl by default: it is what makes a fully static binary possible.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{});

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

    const shared = b.addModule("shared", .{
        .root_source_file = b.path("shared/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const agent_mod = agent.add(b, .{
        .target = target,
        .optimize = optimize,
        .test_step = test_step,
        .log = log_mod,
    });

    const server_mod = server.add(b, .{
        .target = target,
        .optimize = optimize,
        .test_step = test_step,
        .log = log_mod,
        .agent = agent_mod,
    });

    server_mod.addImport("shared", shared);
    agent_mod.addImport("shared", shared);

    const client_mod = b.addModule("client", .{
        .root_source_file = b.path("client/client.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "server", .module = server_mod },
            .{ .name = "shared", .module = shared },
            .{ .name = "log", .module = log_mod },
        },
    });
    const client_tests = b.addTest(.{ .root_module = client_mod });
    test_step.dependOn(&b.addRunArtifact(client_tests).step);

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
    exe.root_module.addImport("server", server_mod);
    exe.root_module.addImport("shared", shared);
    exe.root_module.addImport("client", client_mod);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const shared_tests = b.addTest(.{ .root_module = shared });
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);

    const mod_tests = b.addTest(.{ .root_module = cli_mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
