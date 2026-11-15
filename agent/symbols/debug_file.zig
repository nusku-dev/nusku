/// A stripped binary's symbols or DWARF, from its debug file on this machine. Only the section
/// headers are read here; the sections themselves are streamed like the binary's own.
const std = @import("std");
const elf_file = @import("../elf/elf.zig").file;
const Binary = @import("binary.zig").Binary;

const shared = @import("shared");

const File = shared.File;
const Section = shared.protocol.binary.Section;
const elf = shared.elf;

const root = "/usr/lib/debug/.build-id/";
const path_bytes_max = root.len + 2 * 64 + 8;
const symbol_sections = [_]Section{ .symtab, .strtab };
const dwarf_sections = [_]Section{
    .debug_info, .debug_abbrev,      .debug_line,   .debug_str,      .debug_line_str,
    .debug_addr, .debug_str_offsets, .debug_ranges, .debug_rnglists,
};

pub fn attach(binary: *Binary, id: []const u8) void {
    const symbols_missing = binary.header.sizes.get(.symtab) == 0;
    const dwarf_missing = binary.header.sizes.get(.debug_info) == 0;
    if (!symbols_missing and !dwarf_missing) return;
    var file = open(id) orelse return;
    var loaded = elf_file.load(&file, &.{}, 0) catch {
        file.deinit();
        return;
    };
    defer loaded.deinit();
    if (symbols_missing) sections_take(binary, loaded.bytes, &symbol_sections);
    if (dwarf_missing) sections_take(binary, loaded.bytes, &dwarf_sections);
    if (binary.from_debug.count() == 0) {
        file.deinit();
        return;
    }
    binary.debug = file;
    binary.header.debug_file = true;
}

/// The debug file of `build_id`, or null when none is installed.
pub fn open(build_id: []const u8) ?File {
    var buffer: [path_bytes_max]u8 = undefined;
    const found = path(&buffer, build_id) orelse return null;
    return File.open(found) catch null;
}

/// Takes the group only when its first section is there: never half of it from each file.
fn sections_take(binary: *Binary, bytes: []const u8, group: []const Section) void {
    const first = (elf.find(bytes, group[0].name()) catch return) orelse return;
    if (elf.bytes_of(bytes, first) == null) return;
    for (group) |section| {
        binary.header.sizes.set(section, 0);
        binary.header.compressed.remove(section);
        binary.from_debug.remove(section);
        const found = (elf.find(bytes, section.name()) catch continue) orelse continue;
        const content = elf.bytes_of(bytes, found) orelse continue;
        binary.header.sizes.set(section, content.len);
        binary.starts.set(section, found.offset);
        binary.from_debug.insert(section);
        if (found.flags & elf.shf_compressed != 0) binary.header.compressed.insert(section);
    }
}

/// `/usr/lib/debug/.build-id/ab/cdef….debug` for the build ID `abcdef…`.
fn path(buffer: *[path_bytes_max]u8, build_id: []const u8) ?[:0]const u8 {
    if (build_id.len < 2 or build_id.len > 64) return null;
    const first = std.fmt.bytesToHex(build_id[0..1], .lower);
    var rest_buffer: [2 * 64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (build_id[1..], 0..) |byte, i| {
        rest_buffer[2 * i] = digits[byte >> 4];
        rest_buffer[2 * i + 1] = digits[byte & 0xf];
    }
    const rest = rest_buffer[0 .. 2 * (build_id.len - 1)];
    return std.fmt.bufPrintZ(buffer, "{s}{s}/{s}.debug", .{ root, &first, rest }) catch null;
}

const testing = std.testing;

test "the path of a build ID splits off its first byte" {
    var buffer: [path_bytes_max]u8 = undefined;
    const found = path(&buffer, &.{ 0xa4, 0xa7, 0x99, 0x2a }).?;
    try testing.expectEqualStrings("/usr/lib/debug/.build-id/a4/a7992a.debug", found);
    try testing.expect(path(&buffer, &.{0xa4}) == null);
}

test "an ID with no debug file installed opens nothing" {
    try testing.expect(open(&.{ 0, 1, 2, 3, 4, 5, 6, 7 }) == null);
}
