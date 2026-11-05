//! Reads the GNU build ID of an ELF file: a unique fingerprint the backend uses to find the
//! matching binary or debug info. Only the first part of the file is read, and the section
//! headers when the program headers do not lead to the ID (Go's linker leaves it out of its
//! note segment).

const std = @import("std");
const File = @import("shared").File;
const process_maps = @import("process_maps.zig");
const process = @import("../os/process.zig");

/// How much of the start of a file we read. The ELF header, the program headers and the
/// note segments lie in there for practically every binary. If a note does not, the file is
/// reported as having no build ID.
pub const prefix_size = 64 * 1024;
/// Longer build IDs are refused. GNU ld writes 20 bytes (SHA-1); 64 leaves room for any hash.
pub const id_bytes_max = 64;

const PT_NOTE = 4;
const SHT_NOTE = 7;
const NT_GNU_BUILD_ID = 3;
/// The size of one section header (Elf64_Shdr).
const section_header_size = 64;
/// More sections than this is not a file whose notes we look for; a linked binary has a few
/// dozen.
const sections_max = 256;

/// The build ID of an open ELF file, read into `prefix_buffer` (at least `prefix_size` bytes):
/// from its note segments, else from its note sections. Null if it has none. The result points
/// into `prefix_buffer`.
pub fn from_file(file: *const File, prefix_buffer: []u8) ?[]const u8 {
    std.debug.assert(prefix_buffer.len >= prefix_size);
    const prefix_read = file.read_at(prefix_buffer[0..prefix_size], 0) catch return null;
    const prefix = prefix_buffer[0..prefix_read];
    if (from_prefix(prefix)) |id| return id;

    // Go's linker writes a note segment that holds only its own note, the GNU one just after
    // it: only the section headers, at the end of the file, show where that one is.
    if (prefix.len < 64) return null;
    const offset = read(u64, prefix, 40) orelse return null;
    const entry_size = read(u16, prefix, 58) orelse return null;
    const count = read(u16, prefix, 60) orelse return null;
    if (entry_size != section_header_size or count == 0 or count > sections_max) return null;

    var headers_buffer: [sections_max * section_header_size]u8 = undefined;
    const headers = headers_buffer[0 .. @as(usize, count) * section_header_size];
    const got = file.read_at(headers, offset) catch return null;
    if (got != headers.len) return null;
    return from_sections(prefix, headers);
}

/// The build ID in a note section of the file whose first bytes are `prefix` and whose section
/// header table is `headers`, when that section lies inside `prefix`. The result points into
/// `prefix`.
pub fn from_sections(prefix: []const u8, headers: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + section_header_size <= headers.len) : (at += section_header_size) {
        // A section header is: name u32, type u32, flags u64, addr u64, offset u64, size u64.
        if (read(u32, headers, at + 4) != SHT_NOTE) continue;
        const offset = read(u64, headers, at + 24) orelse continue;
        const size = read(u64, headers, at + 32) orelse continue;
        const end = std.math.add(u64, offset, size) catch continue;
        if (end > prefix.len) continue; // Not inside what was read.
        if (find_build_id(prefix[@intCast(offset)..@intCast(end)])) |id| return id;
    }
    return null;
}

/// The build ID inside `prefix`, the first bytes of an ELF file, or null if there is none.
/// The result points into `prefix`.
pub fn from_prefix(prefix: []const u8) ?[]const u8 {
    if (prefix.len < 64 or !std.mem.eql(u8, prefix[0..4], "\x7fELF")) return null;
    if (prefix[4] != 2 or prefix[5] != 1) return null; // only 64-bit little-endian files

    const phoff = read(u64, prefix, 32) orelse return null;
    const phentsize = read(u16, prefix, 54) orelse return null;
    const phnum = read(u16, prefix, 56) orelse return null;
    if (phentsize < 56) return null;

    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        // A program header is: type u32, flags u32, offset u64, ..., filesz u64 at +32.
        const ph = std.math.add(u64, phoff, i * phentsize) catch return null;
        if ((read(u32, prefix, ph) orelse return null) != PT_NOTE) continue;

        const offset = read(u64, prefix, ph +| 8) orelse return null;
        const size = read(u64, prefix, ph +| 32) orelse return null;
        const end = std.math.add(u64, offset, size) catch continue;
        if (end > prefix.len) continue; // this note segment is not inside what we read

        if (find_build_id(prefix[@intCast(offset)..@intCast(end)])) |id| return id;
    }
    return null;
}

/// The build ID of the file behind `mapping`, opened from inside process `pid`'s view of the
/// filesystem (/proc/<pid>/root), so files that only exist inside a container work too, or
/// through the mapping itself when a sandbox hides the path (`process.mapping_open`).
/// Null when the mapping is not a regular file, was deleted, cannot be read, or has no build
/// ID. A missing build ID is normal and must never fail a profile, so read problems also give
/// null. The result lives in `arena`.
pub fn for_mapping(arena: std.mem.Allocator, pid: u32, mapping: process_maps.Mapping) !?[]const u8 {
    if (mapping.deleted or mapping.path.len == 0 or mapping.path[0] != '/') return null;

    var file = process.mapping_open(pid, mapping.path, mapping.start, mapping.end) catch
        return null;
    defer file.deinit();

    var prefix_buffer: [prefix_size]u8 = undefined;
    const id = from_file(&file, &prefix_buffer) orelse return null;
    return try arena.dupe(u8, id);
}

/// Reads an integer at `offset`, or null if it would run past the end of `bytes`.
/// All offsets come from the file, so nothing here is trusted.
fn read(comptime T: type, bytes: []const u8, offset: u64) ?T {
    const at = std.math.cast(usize, offset) orelse return null;
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return null;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn align4(n: usize) usize {
    return std.mem.alignForward(usize, n, 4);
}

/// Walks a sequence of ELF notes and returns the descriptor of the GNU build ID note.
pub fn find_build_id(notes: []const u8) ?[]const u8 {
    var off: usize = 0;
    while (off + 12 <= notes.len) {
        const namesz: usize = read(u32, notes, off) orelse return null;
        const descsz: usize = read(u32, notes, off + 4) orelse return null;
        const kind = read(u32, notes, off + 8) orelse return null;

        const name = off + 12;
        const desc = std.math.add(usize, name, align4(namesz)) catch return null;
        const desc_end = std.math.add(usize, desc, descsz) catch return null;
        if (desc_end > notes.len) return null; // Truncated.

        if (kind == NT_GNU_BUILD_ID and namesz == 4 and descsz > 0 and descsz <= id_bytes_max and
            std.mem.eql(u8, notes[name..][0..4], "GNU\x00"))
        {
            return notes[desc..][0..descsz];
        }
        off = desc + align4(descsz);
    }
    return null;
}

// ------------------------------------------------------------------------------------- tests

fn put(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}

/// A tiny hand-made ELF: header, two program headers, and a note segment holding an ABI tag
/// note followed by a build ID note (bytes 1 to 20).
fn elf_for_test(note_size: u64) [256]u8 {
    var elf = [_]u8{0} ** 256;
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2; // 64-bit
    elf[5] = 1; // little endian
    put(u64, &elf, 32, 64); // e_phoff
    put(u16, &elf, 54, 56); // e_phentsize
    put(u16, &elf, 56, 2); // e_phnum

    put(u32, &elf, 64, 1); // program header 0: PT_LOAD, which must be skipped
    put(u32, &elf, 120, PT_NOTE); // program header 1
    put(u64, &elf, 120 + 8, 176); // its file offset
    put(u64, &elf, 120 + 32, note_size); // its file size

    // Note 1 (20 bytes): an ABI tag, which must be skipped.
    put(u32, &elf, 176, 4);
    put(u32, &elf, 180, 4);
    put(u32, &elf, 184, 1);
    @memcpy(elf[188..192], "GNU\x00");
    // Note 2 (36 bytes): the build ID.
    put(u32, &elf, 196, 4);
    put(u32, &elf, 200, 20);
    put(u32, &elf, 204, NT_GNU_BUILD_ID);
    @memcpy(elf[208..212], "GNU\x00");
    for (0..20) |i| elf[212 + i] = @intCast(i + 1);
    return elf;
}

test "finds the build ID after skipping other notes" {
    const elf = elf_for_test(56);
    const id = from_prefix(&elf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 20), id.len);
    for (id, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), byte);
}

test "malformed or unsupported input gives null, not a crash" {
    // A note segment that claims to reach past what we have.
    try std.testing.expect(from_prefix(&elf_for_test(1000)) == null);
    // A note segment that is cut off in the middle of the build ID.
    try std.testing.expect(from_prefix(&elf_for_test(40)) == null);

    var not_elf = elf_for_test(56);
    not_elf[0] = 'X';
    try std.testing.expect(from_prefix(&not_elf) == null);

    var elf32 = elf_for_test(56);
    elf32[4] = 1; // 32-bit
    try std.testing.expect(from_prefix(&elf32) == null);

    try std.testing.expect(from_prefix("") == null);
    try std.testing.expect(from_prefix(&[_]u8{0} ** 100) == null);
}

test "mappings that are not regular files have no build ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const me = @import("../os/process.zig").current_pid();

    const base = process_maps.Mapping{
        .start = 0,
        .end = 0,
        .offset = 0,
        .inode = 0,
        .path = "",
        .deleted = false,
    };
    const anonymous = base;
    try std.testing.expect(try for_mapping(arena.allocator(), me, anonymous) == null);

    var vdso = base;
    vdso.path = "[vdso]";
    try std.testing.expect(try for_mapping(arena.allocator(), me, vdso) == null);

    var deleted = base;
    deleted.path = "/bin/ls";
    deleted.deleted = true;
    try std.testing.expect(try for_mapping(arena.allocator(), me, deleted) == null);

    var missing = base;
    missing.path = "/no/such/file";
    try std.testing.expect(try for_mapping(arena.allocator(), me, missing) == null);
}

test "real file: the build ID of /bin/ls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const me = @import("../os/process.zig").current_pid();

    const ls = process_maps.Mapping{
        .start = 0,
        .end = 0,
        .offset = 0,
        .inode = 0,
        .path = "/bin/ls",
        .deleted = false,
    };
    const id = (try for_mapping(arena.allocator(), me, ls)) orelse {
        std.debug.print("build id of /bin/ls: none\n", .{});
        return;
    };
    try std.testing.expect(id.len >= 16 and id.len <= 64);
}

/// A section header table with one note section, for `elf_for_test`'s notes: both of them.
fn note_section_for_test() [2 * section_header_size]u8 {
    var headers = [_]u8{0} ** (2 * section_header_size);
    put(u32, &headers, 4, 1); // Section 0: PROGBITS, which must be skipped.
    put(u32, &headers, section_header_size + 4, SHT_NOTE);
    put(u64, &headers, section_header_size + 24, 176); // Its file offset.
    put(u64, &headers, section_header_size + 32, 56); // Its size.
    return headers;
}

test "a note segment without the build ID (as Go writes it): the note section has it" {
    // The segment holds the first note only, like Go's, which holds its own note only.
    const elf = elf_for_test(20);
    try std.testing.expect(from_prefix(&elf) == null);

    const headers = note_section_for_test();
    const id = from_sections(&elf, &headers) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 20), id.len);
    try std.testing.expectEqual(@as(u8, 1), id[0]);

    // A note section that reaches past what was read is not looked into.
    var outside = headers;
    put(u64, &outside, section_header_size + 24, 250);
    try std.testing.expect(from_sections(&elf, &outside) == null);
    try std.testing.expect(from_sections(&elf, &.{}) == null);
}
