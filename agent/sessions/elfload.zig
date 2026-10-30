//! Loads just enough of an ELF file to read its unwind information: the headers, the section
//! names and the .eh_frame section. The result is as large as the file, so every offset in it
//! is the real file offset, but only the parts that were read cost memory. Everything in the
//! file is untrusted, so each offset is checked against the file size before it is used.
const std = @import("std");
const f = @import("../clibs/file.zig");
const sys = @import("../clibs/anonymous_memory.zig");
const FileError = f.OpenError || f.ReadError;
const File = f.File;

/// Address space only, so this can be generous. Larger files are refused, not truncated.
pub const max_file_size: u64 = 4 << 30;

pub const Loaded = struct {
    /// As long as the file. Parts that were not read are zeros that cost nothing.
    bytes: []align(std.heap.page_size_min) u8,
    /// How many bytes were actually read from the file.
    read: u64,

    pub fn deinit(self: *Loaded) void {
        sys.release(self.bytes);
        self.* = undefined;
    }
};

pub const Section = struct { offset: u64, size: u64 };

const SHT_NOBITS = 8;
const section_header_size = 64;

const Header = struct { name: u32, kind: u32, offset: u64, size: u64 };

fn get(comptime T: type, bytes: []const u8, at: u64) ?T {
    const i = std.math.cast(usize, at) orelse return null;
    if (i > bytes.len or bytes.len - i < @sizeOf(T)) return null;
    return std.mem.readInt(T, bytes[i..][0..@sizeOf(T)], .little);
}

fn inside(total: u64, offset: u64, len: u64) bool {
    return offset <= total and len <= total - offset;
}

fn header(bytes: []const u8, table: u64, index: u64) ?Header {
    const at = std.math.add(u64, table, index * section_header_size) catch return null;
    return .{
        .name = get(u32, bytes, at) orelse return null,
        .kind = get(u32, bytes, at + 4) orelse return null,
        .offset = get(u64, bytes, at + 24) orelse return null,
        .size = get(u64, bytes, at + 32) orelse return null,
    };
}

/// The section called `wanted`, if its headers and the name table are present in `bytes`.
pub fn findSection(bytes: []const u8, wanted: []const u8) ?Section {
    const table = get(u64, bytes, 40) orelse return null;
    const entry_size = get(u16, bytes, 58) orelse return null;
    const count = get(u16, bytes, 60) orelse return null;
    const names_index = get(u16, bytes, 62) orelse return null;
    if (table == 0 or count == 0 or entry_size != section_header_size or names_index >= count) return null;
    if (!inside(bytes.len, table, @as(u64, count) * section_header_size)) return null;

    const names = header(bytes, table, names_index) orelse return null;
    if (!inside(bytes.len, names.offset, names.size)) return null;

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const s = header(bytes, table, i) orelse return null;
        if (s.kind == SHT_NOBITS or !inside(bytes.len, s.offset, s.size)) continue;
        // The name, followed by its zero byte, must lie inside the name table.
        if (s.name >= names.size or names.size - s.name < wanted.len + 1) continue;
        const at: usize = @intCast(names.offset + s.name);
        if (std.mem.eql(u8, bytes[at..][0..wanted.len], wanted) and bytes[at + wanted.len] == 0) {
            return .{ .offset = s.offset, .size = s.size };
        }
    }
    return null;
}

fn fill(file: File, bytes: []u8, offset: u64, len: u64, total: *u64) !void {
    if (!inside(bytes.len, offset, len)) return error.NotElf;
    const start: usize = @intCast(offset);
    const n = try file.read_at(bytes[start..][0..@intCast(len)], offset);
    if (n != len) return error.ReadFailed; // the file got shorter while we read it
    total.* += len;
}

/// Reads what is needed from an open file. A file with no section headers loads fine; it
/// just has no sections to find.
pub fn load(file: File) !Loaded {
    const size = try file.size_bytes();
    if (size < 64) return error.NotElf;
    if (size > max_file_size) return error.TooLarge;

    const bytes = try sys.reserve(@intCast(size));
    errdefer sys.release(bytes);
    var read: u64 = 0;

    try fill(file, bytes, 0, 64, &read);
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    if (bytes[4] != 2 or bytes[5] != 1) return error.Unsupported; // 64-bit, little endian only
    if (get(u16, bytes, 18).? != 62) return error.Unsupported; // x86-64 only for now

    const ph_offset = get(u64, bytes, 32).?;
    const ph_size = get(u16, bytes, 54).?;
    const ph_count = get(u16, bytes, 56).?;
    if (ph_count > 0) {
        if (ph_size != 56) return error.NotElf;
        try fill(file, bytes, ph_offset, @as(u64, ph_count) * ph_size, &read);
    }

    const table = get(u64, bytes, 40).?;
    const entry_size = get(u16, bytes, 58).?;
    const count = get(u16, bytes, 60).?;
    const names_index = get(u16, bytes, 62).?;
    if (table != 0 and count != 0) {
        if (entry_size != section_header_size or names_index >= count) return error.NotElf;
        try fill(file, bytes, table, @as(u64, count) * section_header_size, &read);
        const names = header(bytes, table, names_index) orelse return error.NotElf;
        try fill(file, bytes, names.offset, names.size, &read);
        if (findSection(bytes, ".eh_frame")) |eh| try fill(file, bytes, eh.offset, eh.size, &read);
    }
    return .{ .bytes = bytes, .read = read };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Reads a whole file into memory, for /proc and /sys files, whose size is not known in
/// advance. Fails with TooLarge instead of growing past `max_bytes`.
pub fn readFile(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ![]u8 {
    var file = try File.open(path);
    defer file.deinit();

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&chunk);
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > max_bytes) return error.TooLarge;
        try list.appendSlice(gpa, chunk[0..len]);
    }
    return list.toOwnedSlice(gpa);
}

test "our own executable: the parts read are the same as in the whole file, and much smaller" {
    var file = try File.open("/proc/self/exe");
    defer file.deinit();
    var loaded = try load(file);
    defer loaded.deinit();

    const full = try readFile(testing.allocator, "/proc/self/exe", 1 << 30);
    defer testing.allocator.free(full);
    try testing.expectEqual(full.len, loaded.bytes.len);

    const eh = findSection(full, ".eh_frame") orelse return error.TestUnexpectedResult;
    const there = findSection(loaded.bytes, ".eh_frame") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(eh.offset, there.offset);
    try testing.expectEqual(eh.size, there.size);
    const a: usize = @intCast(eh.offset);
    const n: usize = @intCast(eh.size);
    try testing.expectEqualSlices(u8, full[a..][0..n], loaded.bytes[a..][0..n]);

    try testing.expect(loaded.read < full.len);
    std.debug.print("elfload: read {d} of {d} bytes ({d} bytes of .eh_frame)\n", .{ loaded.read, full.len, eh.size });
}

test "a file that is not ELF is refused" {
    var file = File.open("/etc/passwd") catch return error.SkipZigTest;
    defer file.deinit();
    try testing.expectError(error.NotElf, load(file));
}

test "an empty file, and a missing section" {
    // /proc files report size 0.
    var file = try File.open("/proc/self/cmdline");
    defer file.deinit();
    try testing.expectError(error.NotElf, load(file));

    try testing.expect(findSection("too short", ".eh_frame") == null);
    try testing.expect(findSection(&([_]u8{0} ** 128), ".eh_frame") == null);
}
