//! Loads an ELF file's headers and only the sections asked for.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;
const anonymous_memory = @import("../os/os.zig").anonymous_memory;
const elf = @import("shared").elf;

pub const file_size_max: u64 = 4 << 30;

const elf_header_size = 64;
const program_header_size = 56;
const section_header_size = 64;
const machine_x86_64 = 62;
const names_size_max = 1 << 20;

pub const sections_unwind = [_][]const u8{ ".eh_frame", ".gopclntab", ".debug_frame" };

pub const Loaded = struct {
    bytes: []align(std.heap.page_size_min) u8,
    read_size: u64,

    pub fn deinit(loaded: *Loaded) void {
        anonymous_memory.release(loaded.bytes);
        loaded.* = undefined;
    }
};

pub fn load(file: *const File, sections: []const []const u8, read_max: u64) !Loaded {
    const size = try file.size_bytes();
    if (size < elf_header_size) return error.NotElf;
    if (size > file_size_max) return error.TooLarge;

    const bytes = try anonymous_memory.reserve(@intCast(size));
    errdefer anonymous_memory.release(bytes);
    var read_size: u64 = 0;

    try range_read(file, bytes, 0, elf_header_size, &read_size);
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    if (bytes[4] != 2) return error.Unsupported;
    if (bytes[5] != 1) return error.Unsupported;
    if (int_read(u16, bytes, 18) != machine_x86_64) return error.Unsupported;

    const program_headers_offset = int_read(u64, bytes, 32);
    const program_header_size_found = int_read(u16, bytes, 54);
    const program_header_count = int_read(u16, bytes, 56);
    if (program_header_count > 0) {
        if (program_header_size_found != program_header_size) return error.NotElf;
        const table_size = @as(u64, program_header_count) * program_header_size;
        try range_read(file, bytes, program_headers_offset, table_size, &read_size);
    }

    const section_headers_offset = int_read(u64, bytes, 40);
    const section_header_size_found = int_read(u16, bytes, 58);
    const section_count = int_read(u16, bytes, 60);
    const section_names_index = int_read(u16, bytes, 62);
    if (section_headers_offset != 0 and section_count != 0) {
        if (section_header_size_found != section_header_size) return error.NotElf;
        if (section_names_index >= section_count) return error.NotElf;
        const table_size = @as(u64, section_count) * section_header_size;
        try range_read(file, bytes, section_headers_offset, table_size, &read_size);

        const names_header =
            section_headers_offset + @as(u64, section_names_index) * section_header_size;
        const names_offset = int_read(u64, bytes, names_header + 24);
        const names_size = int_read(u64, bytes, names_header + 32);
        if (names_size > names_size_max) return error.TooLarge;
        try range_read(file, bytes, names_offset, names_size, &read_size);

        for (sections) |name| {
            const found = elf.find(bytes, name) catch return error.NotElf;
            if (found) |section| {
                const room = std.math.sub(u64, read_max, read_size) catch return error.TooLarge;
                if (section.size > room) return error.TooLarge;
                try range_read(file, bytes, section.offset, section.size, &read_size);
            }
        }
    }
    assert(read_size <= size);
    return .{ .bytes = bytes, .read_size = read_size };
}

fn range_read(file: *const File, bytes: []u8, offset: u64, size: u64, read_size: *u64) !void {
    if (offset > bytes.len) return error.NotElf;
    if (size > bytes.len - offset) return error.NotElf;
    if (size == 0) return;

    const start: usize = @intCast(offset);
    const read = try file.read_at(bytes[start..][0..@intCast(size)], offset);
    if (read != size) return error.ReadFailed;
    read_size.* += size;
}

fn int_read(comptime T: type, bytes: []const u8, offset: u64) T {
    assert(offset + @sizeOf(T) <= bytes.len);
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

const testing = std.testing;

fn file_read_whole(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var file = try File.open(path);
    defer file.deinit();

    const size: usize = @intCast(try file.size_bytes());
    const bytes = try gpa.alloc(u8, size);
    errdefer gpa.free(bytes);
    if (try file.read_at(bytes, 0) != size) return error.ReadFailed;
    return bytes;
}

test "our own executable: the parts read are the same as in the file, and much smaller" {
    var file = try File.open("/proc/self/exe");
    defer file.deinit();
    var loaded = try load(&file, &sections_unwind, file_size_max);
    defer loaded.deinit();

    const whole = try file_read_whole(testing.allocator, "/proc/self/exe");
    defer testing.allocator.free(whole);
    try testing.expectEqual(whole.len, loaded.bytes.len);

    const expected = (try elf.find(whole, ".eh_frame")) orelse
        return error.TestUnexpectedResult;
    const found = (try elf.find(loaded.bytes, ".eh_frame")) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(expected.offset, found.offset);
    try testing.expectEqual(expected.size, found.size);

    const start: usize = @intCast(expected.offset);
    const size: usize = @intCast(expected.size);
    try testing.expectEqualSlices(u8, whole[start..][0..size], loaded.bytes[start..][0..size]);
    try testing.expect(loaded.read_size < whole.len);
}

test "a file that is not ELF is refused" {
    var file = File.open("/etc/passwd") catch return error.SkipZigTest;
    defer file.deinit();
    try testing.expectError(error.NotElf, load(&file, &sections_unwind, file_size_max));
}

test "a file that reports size 0, as every /proc file does, is refused" {
    var file = try File.open("/proc/self/cmdline");
    defer file.deinit();
    try testing.expectError(error.NotElf, load(&file, &sections_unwind, file_size_max));
}

test "a section over the limit is refused, and symbol sections are read when asked" {
    var file = try File.open("/proc/self/exe");
    defer file.deinit();
    try testing.expectError(error.TooLarge, load(&file, &sections_unwind, 1));

    var loaded = try load(&file, &.{ ".symtab", ".strtab" }, file_size_max);
    defer loaded.deinit();
    const symbols = (try elf.find(loaded.bytes, ".symtab")) orelse return error.SkipZigTest;
    const names = (try elf.find(loaded.bytes, ".strtab")) orelse return error.SkipZigTest;
    const symbols_bytes = elf.bytes_of(loaded.bytes, symbols) orelse
        return error.TestUnexpectedResult;
    const names_bytes = elf.bytes_of(loaded.bytes, names) orelse
        return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOfNone(u8, symbols_bytes, &.{0}) != null);
    try testing.expect(std.mem.indexOfNone(u8, names_bytes, &.{0}) != null);
}
