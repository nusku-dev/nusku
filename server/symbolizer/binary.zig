//! One loaded executable or library: its bytes, its parsed ELF and its symbol index.
const std = @import("std");
const elf = @import("elf.zig");
const index = @import("index.zig");
const files = @import("files.zig");

pub const Match = index.Match;

/// No real binary is anywhere near this size, and it keeps a bad path (a device, a huge
/// core file) from eating the server's memory.
pub const max_binary_bytes = 1024 * 1024 * 1024;

pub const Binary = struct {
    /// Owned. The ELF and the symbol names point into it.
    bytes: []u8,
    elf: elf.Elf,
    index: index.Index,

    /// Takes over `bytes`, which must have been allocated with `allocator`. They are freed
    /// if this fails, so the caller never has to.
    pub fn load(allocator: std.mem.Allocator, bytes: []u8) !Binary {
        errdefer allocator.free(bytes);
        const file = try elf.Elf.parse(bytes);
        const idx = try index.Index.build(allocator, file);
        return .{ .bytes = bytes, .elf = file, .index = idx };
    }

    /// Reads the file at `path` and loads it.
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) !Binary {
        const bytes = try files.readAll(allocator, path, max_binary_bytes);
        return load(allocator, bytes);
    }

    pub fn deinit(self: *Binary, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn buildId(self: Binary) ?[]const u8 {
        return self.elf.buildId();
    }

    /// True if this file has exactly the build ID the agent saw. A file without a build ID
    /// never matches, because there is nothing to prove it is the same file.
    pub fn matches(self: Binary, expected: []const u8) bool {
        const id = self.buildId() orelse return false;
        return std.mem.eql(u8, id, expected);
    }

    /// The function stored at `file_offset`: the offset becomes a virtual address through the
    /// loadable segments, and the address is looked up in the symbols.
    pub fn resolve(self: Binary, file_offset: u64) ?Match {
        const vaddr = self.elf.vaddrOf(file_offset) orelse return null;
        return self.index.lookup(vaddr);
    }
};

// ------------------------------------------------------------------ tests

fn w16(buf: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], value, .little);
}

fn w32(buf: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], value, .little);
}

fn w64(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

pub const glue_size = elf.sym_file_size + 56;

/// The hand-made file with symbols from `elf.symFile`, plus one loadable segment: file
/// offsets 0x100..0x300 are loaded at virtual addresses 0x1100..0x1300, so file offset
/// 0x130 is virtual address 0x1130, where `main` starts.
pub fn glueFile(buf: *[glue_size]u8) void {
    var base: [elf.sym_file_size]u8 = undefined;
    elf.symFile(&base);
    @memset(buf, 0);
    @memcpy(buf[0..elf.sym_file_size], &base);

    const phdr = elf.sym_file_size; // the program header goes right after the symbol data
    w64(buf, 32, phdr);
    w16(buf, 54, 56);
    w16(buf, 56, 1);
    w32(buf, phdr, 1); // a loadable segment
    w32(buf, phdr + 4, 5);
    w64(buf, phdr + 8, 0x100); // where it is in the file
    w64(buf, phdr + 16, 0x1100); // where it is in memory
    w64(buf, phdr + 24, 0x1100);
    w64(buf, phdr + 32, 0x200); // size in the file
    w64(buf, phdr + 40, 0x200);
    w64(buf, phdr + 48, 0x1000);
}

test "resolve goes from a file offset through the segment to the function" {
    var buf: [glue_size]u8 = undefined;
    glueFile(&buf);
    const allocator = std.testing.allocator;
    var bin = try Binary.load(allocator, try allocator.dupe(u8, &buf));
    defer bin.deinit(allocator);

    const start = bin.resolve(0x130) orelse return error.TestUnexpectedResult; // virtual address 0x1130
    try std.testing.expectEqualStrings("main", start.name);
    try std.testing.expectEqual(@as(u64, 0), start.offset);

    const inside = bin.resolve(0x16f) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("main", inside.name);
    try std.testing.expectEqual(@as(u64, 0x3f), inside.offset);

    const second = bin.resolve(0x170) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("helper", second.name);
    try std.testing.expectEqual(@as(u64, 0), second.offset);

    try std.testing.expect(bin.resolve(0x1f0) == null); // virtual address 0x11f0, past every function
    try std.testing.expect(bin.resolve(0xff) == null); // before the segment
    try std.testing.expect(bin.resolve(0x300) == null); // the segment's end is exclusive
}

test "matches: a file without a build ID matches nothing" {
    var buf: [glue_size]u8 = undefined;
    glueFile(&buf);
    const allocator = std.testing.allocator;
    var bin = try Binary.load(allocator, try allocator.dupe(u8, &buf));
    defer bin.deinit(allocator);

    try std.testing.expect(bin.buildId() == null);
    try std.testing.expect(!bin.matches(&.{ 1, 2, 3 }));
}

test "load takes the bytes and frees them when the file is not an ELF file" {
    const bytes = try std.testing.allocator.dupe(u8, "this is not an elf file, it is only text");
    try std.testing.expectError(error.NotElf, Binary.load(std.testing.allocator, bytes));
    // The testing allocator reports a leak if load had not freed the bytes.
}

test "open reports a missing file" {
    try std.testing.expectError(error.NotFound, Binary.open(std.testing.allocator, "/does/not/exist"));
}
