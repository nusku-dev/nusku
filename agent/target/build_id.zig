//! What names an ELF file: its GNU build ID, else its Go one, else the file itself.

const std = @import("std");
const File = @import("shared").File;
const process_maps = @import("process_maps.zig");
const process = @import("../os/os.zig").process;

pub const prefix_size = 64 * 1024;
pub const id_bytes_max = 64;
pub const derived_bytes = 20;

const PT_NOTE = 4;
const SHT_NOTE = 7;
const NT_GNU_BUILD_ID = 3;
const NT_GO_BUILD_ID = 4;
const section_header_size = 64;
const sections_max = 256;

pub fn from_file(file: *const File, prefix_buffer: []u8) ?[]const u8 {
    std.debug.assert(prefix_buffer.len >= prefix_size);
    const prefix_read = file.read_at(prefix_buffer[0..prefix_size], 0) catch return null;
    const prefix = prefix_buffer[0..prefix_read];
    if (!elf64(prefix)) return null;
    if (from_prefix(prefix)) |id| return id;

    var headers_buffer: [sections_max * section_header_size]u8 = undefined;
    const headers = section_headers(file, prefix, &headers_buffer);
    if (from_sections(prefix, headers)) |id| return id;

    if (notes_find(prefix, headers, .go)) |go| return derived(prefix_buffer, "go", go);
    const found = file.stat() catch return null;
    var source: [32]u8 = undefined;
    put(u32, &source, 0, found.device_major);
    put(u32, &source, 4, found.device_minor);
    put(u64, &source, 8, found.inode);
    put(u64, &source, 16, found.size);
    put(i64, &source, 24, found.modified_s);
    return derived(prefix_buffer, "file", &source);
}

fn section_headers(file: *const File, prefix: []const u8, buffer: []u8) []const u8 {
    const offset = read(u64, prefix, 40) orelse return &.{};
    const entry_size = read(u16, prefix, 58) orelse return &.{};
    const count = read(u16, prefix, 60) orelse return &.{};
    if (entry_size != section_header_size or count == 0 or count > sections_max) return &.{};
    const headers = buffer[0 .. @as(usize, count) * section_header_size];
    const got = file.read_at(headers, offset) catch return &.{};
    if (got != headers.len) return &.{};
    return headers;
}

/// Written over the start of `prefix_buffer`, once `source` is read.
fn derived(prefix_buffer: []u8, kind: []const u8, source: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("nusku ");
    hasher.update(kind);
    hasher.update(source);
    hasher.final(&digest);
    @memcpy(prefix_buffer[0..derived_bytes], digest[0..derived_bytes]);
    return prefix_buffer[0..derived_bytes];
}

fn elf64(prefix: []const u8) bool {
    return prefix.len >= 64 and std.mem.eql(u8, prefix[0..4], "\x7fELF") and
        prefix[4] == 2 and prefix[5] == 1;
}

const Note = enum { gnu, go };

fn notes_find(prefix: []const u8, headers: []const u8, note: Note) ?[]const u8 {
    return notes_in_segments(prefix, note) orelse notes_in_sections(prefix, headers, note);
}

pub fn from_sections(prefix: []const u8, headers: []const u8) ?[]const u8 {
    return notes_in_sections(prefix, headers, .gnu);
}

fn notes_in_sections(prefix: []const u8, headers: []const u8, note: Note) ?[]const u8 {
    var at: usize = 0;
    while (at + section_header_size <= headers.len) : (at += section_header_size) {
        if (read(u32, headers, at + 4) != SHT_NOTE) continue;
        const offset = read(u64, headers, at + 24) orelse continue;
        const size = read(u64, headers, at + 32) orelse continue;
        const end = std.math.add(u64, offset, size) catch continue;
        if (end > prefix.len) continue;
        if (note_find(prefix[@intCast(offset)..@intCast(end)], note)) |id| return id;
    }
    return null;
}

pub fn from_prefix(prefix: []const u8) ?[]const u8 {
    return notes_in_segments(prefix, .gnu);
}

fn notes_in_segments(prefix: []const u8, note: Note) ?[]const u8 {
    if (!elf64(prefix)) return null;

    const phoff = read(u64, prefix, 32) orelse return null;
    const phentsize = read(u16, prefix, 54) orelse return null;
    const phnum = read(u16, prefix, 56) orelse return null;
    if (phentsize < 56) return null;

    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        const ph = std.math.add(u64, phoff, i * phentsize) catch return null;
        if ((read(u32, prefix, ph) orelse return null) != PT_NOTE) continue;

        const offset = read(u64, prefix, ph +| 8) orelse return null;
        const size = read(u64, prefix, ph +| 32) orelse return null;
        const end = std.math.add(u64, offset, size) catch continue;
        if (end > prefix.len) continue;

        if (note_find(prefix[@intCast(offset)..@intCast(end)], note)) |id| return id;
    }
    return null;
}

pub fn for_mapping(arena: std.mem.Allocator, pid: u32, mapping: process_maps.Mapping) !?[]const u8 {
    if (mapping.deleted or mapping.path.len == 0 or mapping.path[0] != '/') return null;

    var file = process.mapping_open(pid, mapping.path, mapping.start, mapping.end) catch
        return null;
    defer file.deinit();

    var prefix_buffer: [prefix_size]u8 = undefined;
    const id = from_file(&file, &prefix_buffer) orelse return null;
    return try arena.dupe(u8, id);
}

fn read(comptime T: type, bytes: []const u8, offset: u64) ?T {
    const at = std.math.cast(usize, offset) orelse return null;
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return null;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn align4(n: usize) usize {
    return std.mem.alignForward(usize, n, 4);
}

pub fn find_build_id(notes: []const u8) ?[]const u8 {
    return note_find(notes, .gnu);
}

fn note_find(notes: []const u8, note: Note) ?[]const u8 {
    const kind_wanted: u32 = if (note == .gnu) NT_GNU_BUILD_ID else NT_GO_BUILD_ID;
    const name_wanted = if (note == .gnu) "GNU\x00" else "Go\x00\x00";
    var off: usize = 0;
    while (off + 12 <= notes.len) {
        const namesz: usize = read(u32, notes, off) orelse return null;
        const descsz: usize = read(u32, notes, off + 4) orelse return null;
        const kind = read(u32, notes, off + 8) orelse return null;

        const name = off + 12;
        const desc = std.math.add(usize, name, align4(namesz)) catch return null;
        const desc_end = std.math.add(usize, desc, descsz) catch return null;
        if (desc_end > notes.len) return null;

        const fits = note == .go or descsz <= id_bytes_max;
        if (kind == kind_wanted and namesz == 4 and descsz > 0 and fits and
            std.mem.eql(u8, notes[name..][0..4], name_wanted))
        {
            return notes[desc..][0..descsz];
        }
        off = desc + align4(descsz);
    }
    return null;
}

fn put(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}

fn elf_for_test(note_size: u64) [256]u8 {
    var elf = [_]u8{0} ** 256;
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2;
    elf[5] = 1;
    put(u64, &elf, 32, 64);
    put(u16, &elf, 54, 56);
    put(u16, &elf, 56, 2);

    put(u32, &elf, 64, 1);
    put(u32, &elf, 120, PT_NOTE);
    put(u64, &elf, 120 + 8, 176);
    put(u64, &elf, 120 + 32, note_size);

    put(u32, &elf, 176, 4);
    put(u32, &elf, 180, 4);
    put(u32, &elf, 184, 1);
    @memcpy(elf[188..192], "GNU\x00");
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
    try std.testing.expect(from_prefix(&elf_for_test(1000)) == null);
    try std.testing.expect(from_prefix(&elf_for_test(40)) == null);

    var not_elf = elf_for_test(56);
    not_elf[0] = 'X';
    try std.testing.expect(from_prefix(&not_elf) == null);

    var elf32 = elf_for_test(56);
    elf32[4] = 1;
    try std.testing.expect(from_prefix(&elf32) == null);

    try std.testing.expect(from_prefix("") == null);
    try std.testing.expect(from_prefix(&[_]u8{0} ** 100) == null);
}

test "mappings that are not regular files have no build ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const me = @import("../os/os.zig").process.current_pid();

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
    const me = @import("../os/os.zig").process.current_pid();

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

fn note_section_for_test() [2 * section_header_size]u8 {
    var headers = [_]u8{0} ** (2 * section_header_size);
    put(u32, &headers, 4, 1);
    put(u32, &headers, section_header_size + 4, SHT_NOTE);
    put(u64, &headers, section_header_size + 24, 176);
    put(u64, &headers, section_header_size + 32, 56);
    return headers;
}

test "a note segment without the build ID (as Go writes it): the note section has it" {
    const elf = elf_for_test(20);
    try std.testing.expect(from_prefix(&elf) == null);

    const headers = note_section_for_test();
    const id = from_sections(&elf, &headers) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 20), id.len);
    try std.testing.expectEqual(@as(u8, 1), id[0]);

    var outside = headers;
    put(u64, &outside, section_header_size + 24, 250);
    try std.testing.expect(from_sections(&elf, &outside) == null);
    try std.testing.expect(from_sections(&elf, &.{}) == null);
}

test "a Go build ID is found when there is no GNU one" {
    var elf = elf_for_test(56);
    put(u32, &elf, 204, NT_GO_BUILD_ID);
    @memcpy(elf[208..212], "Go\x00\x00");
    try std.testing.expect(from_prefix(&elf) == null);
    const go = notes_find(&elf, &.{}, .go) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 20), go.len);
    try std.testing.expectEqual(@as(u8, 1), go[0]);
}

test "an ELF file with no ID is named by the file, the same way each time" {
    var path_buffer: [64]u8 = undefined;
    const me = @import("../os/os.zig").process.current_pid();
    const path = try std.fmt.bufPrintZ(&path_buffer, "/tmp/nusku-build-id-{d}", .{me});
    defer _ = std.c.unlink(path.ptr);

    var elf = elf_for_test(56);
    put(u32, &elf, 204, 99);
    const out = std.c.fopen(path.ptr, "w") orelse return error.SkipZigTest;
    _ = std.c.fwrite(&elf, 1, elf.len, out);
    _ = std.c.fclose(out);

    var file = try File.open(path);
    defer file.deinit();
    var first: [prefix_size]u8 = undefined;
    var second: [prefix_size]u8 = undefined;
    const a = from_file(&file, &first) orelse return error.TestUnexpectedResult;
    const b = from_file(&file, &second) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, derived_bytes), a.len);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "a file that is not ELF has no ID" {
    var file = try File.open("/proc/self/status");
    defer file.deinit();
    var prefix: [prefix_size]u8 = undefined;
    try std.testing.expect(from_file(&file, &prefix) == null);
}
