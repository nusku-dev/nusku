//! Loads just enough of an ELF file to read its unwind information: the headers, the section
//! names and the .eh_frame section. The result is as long as the file, so every offset in it is
//! the real file offset, but only the parts that were read cost memory: the rest is anonymous
//! address space that reads as zeros. Everything in the file is untrusted, so each offset is
//! checked against the file size before it is used.
//!
//! Sketch: libc is 2 MiB, of which about 60 KiB are headers and .eh_frame. Reading only those
//! is 30 times less memory and disk traffic than reading the file.

const std = @import("std");
const assert = std.debug.assert;
const file_module = @import("../os/file.zig");
const anonymous_memory = @import("../os/anonymous_memory.zig");
const elf_sections = @import("elf_sections.zig");

const File = file_module.File;

/// Address space only, so this can be generous. Larger files are refused, not truncated.
pub const file_size_max: u64 = 4 << 30;

const elf_header_size = 64;
const program_header_size = 56;
const section_header_size = 64;
const machine_x86_64 = 62;

pub const Loaded = struct {
    /// As long as the file. The parts that were not read are zeros that cost nothing.
    bytes: []align(std.heap.page_size_min) u8,
    /// How many bytes were actually read from the file.
    read_size: u64,

    pub fn deinit(loaded: *Loaded) void {
        anonymous_memory.release(loaded.bytes);
        loaded.* = undefined;
    }
};

/// Reads what the unwinder needs from an open file. A file without section headers loads fine;
/// it just has no sections to find.
pub fn load(file: *const File) !Loaded {
    const size = try file.size_bytes();
    if (size < elf_header_size) return error.NotElf;
    if (size > file_size_max) return error.TooLarge;

    const bytes = try anonymous_memory.reserve(@intCast(size));
    errdefer anonymous_memory.release(bytes);
    var read_size: u64 = 0;

    try range_read(file, bytes, 0, elf_header_size, &read_size);
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    if (bytes[4] != 2) return error.Unsupported; // Not 64-bit.
    if (bytes[5] != 1) return error.Unsupported; // Not little endian.
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

        // The name table's header is in the table just read.
        const names_header =
            section_headers_offset + @as(u64, section_names_index) * section_header_size;
        const names_offset = int_read(u64, bytes, names_header + 24);
        const names_size = int_read(u64, bytes, names_header + 32);
        try range_read(file, bytes, names_offset, names_size, &read_size);

        const eh_frame = elf_sections.find(bytes, ".eh_frame") catch return error.NotElf;
        if (eh_frame) |section| {
            try range_read(file, bytes, section.offset, section.size, &read_size);
        }
    }
    assert(read_size <= size);
    return .{ .bytes = bytes, .read_size = read_size };
}

/// Reads `size` bytes at `offset` into the same place in `bytes`.
fn range_read(file: *const File, bytes: []u8, offset: u64, size: u64, read_size: *u64) !void {
    if (offset > bytes.len) return error.NotElf;
    if (size > bytes.len - offset) return error.NotElf;
    if (size == 0) return;

    const start: usize = @intCast(offset);
    const read = try file.read_at(bytes[start..][0..@intCast(size)], offset);
    if (read != size) return error.ReadFailed; // The file got shorter while it was read.
    read_size.* += size;
}

/// The caller checked that the integer is inside `bytes`: the header was read, and its fields
/// sit at fixed offsets inside it.
fn int_read(comptime T: type, bytes: []const u8, offset: u64) T {
    assert(offset + @sizeOf(T) <= bytes.len);
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// The whole file, for comparing with what `load` read.
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
    var loaded = try load(&file);
    defer loaded.deinit();

    const whole = try file_read_whole(testing.allocator, "/proc/self/exe");
    defer testing.allocator.free(whole);
    try testing.expectEqual(whole.len, loaded.bytes.len);

    const expected = (try elf_sections.find(whole, ".eh_frame")) orelse
        return error.TestUnexpectedResult;
    const found = (try elf_sections.find(loaded.bytes, ".eh_frame")) orelse
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
    try testing.expectError(error.NotElf, load(&file));
}

test "a file that reports size 0, as every /proc file does, is refused" {
    var file = try File.open("/proc/self/cmdline");
    defer file.deinit();
    try testing.expectError(error.NotElf, load(&file));
}
