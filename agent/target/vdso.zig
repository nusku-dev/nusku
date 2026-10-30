//! The vDSO: the small shared library the kernel maps into every process, so that reading the
//! clock (clock_gettime, gettimeofday, time) and getcpu need no system call. A program that reads
//! the clock in a hot path spends many of its samples inside it.
//!
//! It has no file on disk, so the agent cannot open it like other libraries. But every 64-bit
//! process on one kernel maps the same image, so the agent copies its own, once: reading its own
//! memory needs no rights, where reading the target's (/proc/<pid>/mem) needs ptrace rights the
//! agent may not have. The image is a complete ELF file, .eh_frame included, so the unwind tables
//! are built from it like from any other binary.
//!
//! A target whose vDSO is not this one (a 32-bit process maps the 32-bit vDSO) is told apart by
//! the size of its [vdso] mapping, and gets no table rather than a wrong one.

const std = @import("std");
const assert = std.debug.assert;
const process = @import("../os/process.zig");
const process_maps = @import("process_maps.zig");
const build_id = @import("build_id.zig");

/// The vDSO is two pages today. Far more would mean the mapping is not what we think it is.
const image_size_max = 64 * 1024;

/// The path /proc/<pid>/maps gives the vDSO's mapping.
pub const path = "[vdso]";

/// `getauxval(AT_SYSINFO_EHDR)`: where the kernel mapped the vDSO's ELF header in this process.
extern "c" fn getauxval(kind: c_ulong) c_ulong;
const auxv_sysinfo_ehdr = std.elf.AT_SYSINFO_EHDR;

pub const Image = struct {
    /// A copy of the whole mapping, owned.
    bytes: []const u8,
    /// Null if the image has no GNU build ID note.
    build_id: ?[]const u8,

    pub fn deinit(image: *Image, gpa: std.mem.Allocator) void {
        gpa.free(image.bytes);
        image.* = undefined;
    }

    /// Whether a [vdso] mapping of `size` bytes in a target is this image.
    pub fn matches(image: *const Image, size: u64) bool {
        return image.bytes.len == size;
    }
};

/// Copies this process's vDSO. Null when the kernel maps none (vdso=0 on its command line), or
/// it is not where the auxiliary vector says: then targets get no vDSO table, nothing more.
pub fn read(gpa: std.mem.Allocator) !?Image {
    const header_address = getauxval(auxv_sysinfo_ehdr);
    if (header_address == 0) return null;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const mappings = try process_maps.read(arena.allocator(), process.current_pid());
    const mapping = for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.path, path)) break mapping;
    } else return null;

    // Two sources must agree before memory is read: the kernel's auxiliary vector and our maps.
    if (mapping.start != header_address) return null;
    const size = mapping.end - mapping.start;
    if (size > image_size_max) return null;
    assert(size > 0);

    // The mapping is readable and executable, and cannot go away while this process lives.
    const memory: [*]const u8 = @ptrFromInt(mapping.start);
    if (!std.mem.eql(u8, memory[0..4], "\x7fELF")) return null;

    const bytes = try gpa.dupe(u8, memory[0..@intCast(size)]);
    // Points into `bytes`, which the image owns.
    return .{ .bytes = bytes, .build_id = build_id.from_prefix(bytes) };
}

test "this process has a vDSO, a whole ELF file with unwind information" {
    var image = (try read(std.testing.allocator)) orelse return error.SkipZigTest;
    defer image.deinit(std.testing.allocator);

    try std.testing.expect(image.bytes.len >= 4096);
    try std.testing.expectEqual(@as(u8, 2), image.bytes[4]); // 64-bit.
    const elf_sections = @import("../unwind/elf_sections.zig");
    const eh_frame = try elf_sections.find(image.bytes, ".eh_frame");
    try std.testing.expect(eh_frame != null);
    try std.testing.expect(image.matches(image.bytes.len));
    try std.testing.expect(!image.matches(image.bytes.len + 4096));
}
