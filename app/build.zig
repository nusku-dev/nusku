const std = @import("std");

/// The port the backend listens on in dev mode. The Vite dev server proxies `/webui.js` here
/// (see ui/vite.config.ts), so the two must agree. A release build picks a free port instead.
const dev_port = 9000;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dev = b.option(bool, "dev", "Load the UI from the Vite dev server instead of embedding it") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "dev", dev);
    options.addOption(u16, "dev_port", dev_port);

    const webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false,
        .is_static = true,
    });

    const exe = b.addExecutable(.{
        .name = "nusku-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webui", .module = webui.module("webui") },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "assets", .module = assets(b, dev) },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the app (add -Ddev to use the Vite dev server)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}

/// The module that holds the UI. In dev mode it is empty: the page comes from Vite. Otherwise
/// the UI is built with Vite and every output file is embedded in the executable.
fn assets(b: *std.Build, dev: bool) *std.Build.Module {
    if (dev) {
        const empty = b.addWriteFiles().add("assets.zig", "pub const files = [_]File{};\n" ++
            "pub const File = struct { path: []const u8, response: []const u8 };\n");
        return b.createModule(.{ .root_source_file = empty });
    }

    // `npm run build` type-checks, then bundles into a directory in the cache. It runs on every
    // build (it has no way to tell Zig which sources it read), but nothing downstream is
    // rebuilt unless the output actually changes.
    const vite = b.addSystemCommand(&.{ "npm", "run", "build", "--", "--emptyOutDir", "--outDir" });
    vite.setCwd(b.path("ui"));
    vite.has_side_effects = true;
    const dist = vite.addOutputDirectoryArg("dist");

    // Turn the output into a Zig source file with one ready-made HTTP response per file.
    const embed_tool = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed.zig"),
            .target = b.graph.host,
        }),
    });
    const embed = b.addRunArtifact(embed_tool);
    embed.has_side_effects = true;
    embed.addDirectoryArg(dist);
    const out = embed.addOutputDirectoryArg("assets");

    return b.createModule(.{ .root_source_file = out.path(b, "assets.zig") });
}
