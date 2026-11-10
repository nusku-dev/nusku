//! The vDSO, the kernel's library for clock_gettime and the like.

const std = @import("std");
const assert = std.debug.assert;
const process = @import("../os/os.zig").process;
const process_maps = @import("process_maps.zig");
const build_id = @import("build_id.zig");
const log = @import("../log.zig").agent;

const image_size_max = 64 * 1024;

pub const path = "[vdso]";

extern "c" fn getauxval(kind: c_ulong) c_ulong;
const auxv_sysinfo_ehdr = std.elf.AT_SYSINFO_EHDR;

pub const Image = struct {
    bytes: []const u8,
    build_id: ?[]const u8,

    pub fn deinit(image: *Image, gpa: std.mem.Allocator) void {
        gpa.free(image.bytes);
        image.* = undefined;
    }

    pub fn matches(image: *const Image, size: u64) bool {
        return image.bytes.len == size;
    }
};

pub fn read(gpa: std.mem.Allocator) !?Image {
    const header_address = getauxval(auxv_sysinfo_ehdr);
    if (header_address == 0) return null;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const mappings = try process_maps.read(arena.allocator(), process.current_pid());
    const mapping = for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.path, path)) break mapping;
    } else return null;

    if (mapping.start != header_address) {
        log.warn("vdso: the auxiliary vector and /proc/self/maps disagree, not reading it", .{});
        return null;
    }
    const size = mapping.end - mapping.start;
    if (size > image_size_max) return null;
    assert(size > 0);

    const memory: [*]const u8 = @ptrFromInt(mapping.start);
    if (!std.mem.eql(u8, memory[0..4], "\x7fELF")) return null;

    const bytes = try gpa.dupe(u8, memory[0..@intCast(size)]);
    const image = Image{ .bytes = bytes, .build_id = build_id.from_prefix(bytes) };
    log.debug("vdso image copied", .{
        .size = bytes.len,
        .build_id_found = image.build_id != null,
    });
    return image;
}

test "this process has a vDSO, a whole ELF file with unwind information" {
    var image = (try read(std.testing.allocator)) orelse return error.SkipZigTest;
    defer image.deinit(std.testing.allocator);

    try std.testing.expect(image.bytes.len >= 4096);
    try std.testing.expectEqual(@as(u8, 2), image.bytes[4]);
    const elf = @import("shared").elf;
    const eh_frame = try elf.find(image.bytes, ".eh_frame");
    try std.testing.expect(eh_frame != null);
    try std.testing.expect(image.matches(image.bytes.len));
    try std.testing.expect(!image.matches(image.bytes.len + 4096));
}
