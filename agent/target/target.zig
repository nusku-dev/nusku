//! The target layer: the process profiled, as the layers above need to know it: its executable
//! regions, the kernel it runs on, and the vDSO it shares with the agent. Also the tools on its
//! files that they share: opening a region's file, checked to be the one mapped. Stands on os.

const std = @import("std");
const os = @import("../os/os.zig");
const process_maps = @import("process_maps.zig");
const regions_file = @import("regions.zig");
const kernel_file = @import("kernel.zig");
const vdso = @import("vdso.zig");
const build_id = @import("build_id.zig");
const mapped_file = @import("mapped_file.zig");
const log = @import("../log.zig").agent;

pub const Region = regions_file.Region;
pub const KernelIdentity = kernel_file.Identity;
pub const VdsoImage = vdso.Image;
/// The path of the [vdso] region: it has no file, its image is `Target.vdso`.
pub const vdso_path = vdso.path;

/// The file behind a region, as the target sees it, checked to be the one it mapped.
/// `prefix_buffer` is `build_id_prefix_size` bytes of scratch.
pub const file_open = mapped_file.open;
pub const FileError = mapped_file.Error;
/// The first bytes of a file, where its build ID is.
pub const build_id_prefix_size = build_id.prefix_size;
pub const build_id_bytes_max = build_id.id_bytes_max;
/// The build ID in the first bytes of an ELF file, or null.
pub const build_id_of = build_id.from_prefix;

pub const Target = struct {
    pid: u32,
    /// The executable regions as of the last `refresh`; kept when the target has exited, so
    /// the last report can still use them.
    regions: []const Region,
    kernel: KernelIdentity,
    /// The agent's own vDSO, which every 64-bit target maps too. Null when there is none.
    vdso: ?VdsoImage,
    /// Owns `kernel`: it cannot change while the agent runs.
    kernel_arena: std.heap.ArenaAllocator,
    /// `regions` live in `regions_arenas[regions_current]`; the next read fills the other,
    /// and reuses the build IDs found by this one.
    regions_arenas: [2]std.heap.ArenaAllocator,
    regions_current: u1,

    /// `ProcessNotFound` when the target has no regions to read: gone, or a zombie.
    pub fn init(gpa: std.mem.Allocator, pid: u32) !Target {
        if (!os.process.pid_valid(pid)) return error.InvalidPid;
        var target = Target{
            .pid = pid,
            .regions = &.{},
            .kernel = .{},
            .vdso = null,
            .kernel_arena = .init(gpa),
            .regions_arenas = .{ .init(gpa), .init(gpa) },
            .regions_current = 0,
        };
        errdefer target.deinit(gpa);

        target.kernel = try kernel_file.read(target.kernel_arena.allocator());
        if (target.kernel.text_address == null) {
            // kptr_restrict hides kernel addresses from a process without CAP_SYSLOG.
            log.warn("kernel addresses are hidden: kernel frames cannot be named", .{
                .needs = "CAP_SYSLOG",
            });
        }
        target.vdso = try vdso.read(gpa);
        if (target.vdso == null) {
            log.warn("no vDSO image: samples inside it will lose their callers", .{});
        }
        if (!try target.refresh()) return error.ProcessNotFound;
        return target;
    }

    pub fn deinit(target: *Target, gpa: std.mem.Allocator) void {
        if (target.vdso) |*image| image.deinit(gpa);
        target.regions_arenas[1].deinit();
        target.regions_arenas[0].deinit();
        target.kernel_arena.deinit();
        target.* = undefined;
    }

    /// Reads the regions again. False when the target has exited: the last ones are kept.
    pub fn refresh(target: *Target) !bool {
        const spare = target.regions_current +% 1;
        const arena = &target.regions_arenas[spare];
        // Keeping the capacity, a steady target's reads stop allocating after the first.
        _ = arena.reset(.retain_capacity);

        const mappings = process_maps.read(arena.allocator(), target.pid) catch |err| switch (err) {
            error.NotFound, error.ProcessNotFound => {
                log.debug("target is gone: keeping its last regions", .{ .pid = target.pid });
                return false;
            },
            else => return err,
        };
        // A zombie has no mappings left.
        if (mappings.len == 0) {
            log.debug("target has exited: keeping its last regions", .{ .pid = target.pid });
            return false;
        }

        const before = target.regions.len;
        const previous = target.regions;
        const built = try regions_file.build(arena.allocator(), mappings, target.pid, previous);
        regions_file.vdso_mark(built, target.vdso_image());
        target.regions = built;
        target.regions_current = spare;
        // The target loaded or unloaded code: dlopen, a plugin, a JIT region.
        if (before != 0 and built.len != before) {
            log.debug("target regions changed", .{ .before = before, .now = built.len });
        }
        return true;
    }

    pub fn vdso_image(target: *const Target) ?*const VdsoImage {
        return if (target.vdso) |*image| image else null;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const child_process = @import("../testing/process.zig");

fn marker() void {} // A function inside this very test binary.

test {
    _ = process_maps;
    _ = regions_file;
    _ = kernel_file;
    _ = vdso;
    _ = build_id;
    _ = mapped_file;
}

test "this process: its regions hold its own code, and the [vdso] has the image's build ID" {
    var target = try Target.init(testing.allocator, os.process.current_pid());
    defer target.deinit(testing.allocator);

    const address = @intFromPtr(&marker);
    const own = for (target.regions) |region| {
        if (address >= region.start and address < region.end) break region;
    } else return error.TestUnexpectedResult;
    try testing.expect(own.build_id != null);
    try testing.expect(target.kernel.release.len > 0);

    const image = target.vdso_image() orelse return;
    const id = image.build_id orelse return;
    for (target.regions) |region| {
        if (std.mem.eql(u8, region.path, vdso_path)) {
            try testing.expectEqualSlices(u8, id, region.build_id.?);
        }
    }
    try testing.expect(try target.refresh()); // Still here.
}

test "a bad pid is refused, and a zombie is not found, leaking nothing" {
    try testing.expectError(error.InvalidPid, Target.init(testing.allocator, 0));

    const child = try child_process.sleeper_spawn();
    var reaped = false;
    defer if (!reaped) child_process.child_reap(child);
    child_process.child_kill(child);
    try child_process.zombie_wait(child);
    try testing.expectError(error.ProcessNotFound, Target.init(testing.allocator, child));
    child_process.child_reap(child);
    reaped = true;
}
