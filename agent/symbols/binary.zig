//! One binary of the target, opened to send its symbols to the server, and the types of that
//! stream: a `Header`, then the section bytes as `Chunk`s. Nothing is parsed here beyond the
//! headers: the server reads the symbol tables, and treats them as untrusted.

const std = @import("std");
const assert = std.debug.assert;
const shared = @import("shared");
const build_id = @import("../target/build_id.zig");
const mapped_file = @import("../target/mapped_file.zig");
const vdso = @import("../target/vdso.zig");
const Region = @import("../target/regions.zig").Region;
const elf_file = @import("../unwind/elf_file.zig");
const vdso_symbols = @import("vdso_symbols.zig");
const kernel_symbols = @import("kernel_symbols.zig");

const elf = shared.elf;
const File = shared.File;

/// More executable segments than this in one file is not a file we describe.
const segments_max = 16;

/// The sections of a binary the server reads its symbols from.
pub const Section = enum {
    symtab,
    strtab,
    dynsym,
    dynstr,

    /// The name in the ELF file.
    pub fn name(section: Section) []const u8 {
        return switch (section) {
            .symtab => ".symtab",
            .strtab => ".strtab",
            .dynsym => ".dynsym",
            .dynstr => ".dynstr",
        };
    }
};

/// Starts the transfer of one binary, sent once per build ID. The section bytes follow as
/// `Chunk`s, so the agent holds one chunk in memory whatever the size of the program. A section
/// the file lacks (a stripped file has no `symtab`) has size 0.
pub const Header = struct {
    build_id: []const u8,
    /// For display only; never opened.
    path: []const u8,
    /// The loadable, executable segments: how an offset in the file becomes the virtual
    /// address that the symbols use.
    segments: []const Segment,
    sizes: std.EnumArray(Section, u64),

    pub const Segment = elf.Segment;

    /// A deep copy into `arena`.
    pub fn clone(header: *const Header, arena: std.mem.Allocator) !Header {
        return .{
            .build_id = try arena.dupe(u8, header.build_id),
            .path = try arena.dupe(u8, header.path),
            .segments = try arena.dupe(Segment, header.segments),
            .sizes = header.sizes,
        };
    }
};

/// A part of one section: `bytes` are the bytes of `section` from `offset`.
pub const Chunk = struct {
    section: Section,
    offset: u64,
    bytes: []const u8,
};

pub const Binary = struct {
    header: Header,
    /// Where each section starts in the file.
    starts: std.EnumArray(Section, u64),
    origin: union(enum) {
        /// The file stays open, and chunks are read from it when asked for.
        file: File,
        /// The vDSO has no file: its sections are in memory, in the agent's own image (which
        /// outlives the binary) or written for it (vdso_symbols.zig). `starts` is unused.
        memory: std.EnumArray(Section, []const u8),
    },

    pub fn deinit(binary: *Binary) void {
        switch (binary.origin) {
            .file => |*file| file.deinit(),
            .memory => {},
        }
        binary.* = undefined;
    }

    /// Reads the bytes of `section` from `offset` into `buffer`, and returns the part that is
    /// filled: shorter than `buffer` only at the end of the section, empty past it.
    /// `error.FileChanged` when the file got shorter since it was opened.
    pub fn read(
        binary: *const Binary,
        section: Section,
        offset: u64,
        buffer: []u8,
    ) ![]const u8 {
        assert(buffer.len > 0);

        const size = binary.header.sizes.get(section);
        if (offset >= size) return buffer[0..0];

        const wanted: usize = @intCast(@min(buffer.len, size - offset));
        switch (binary.origin) {
            .file => |*file| {
                const start = binary.starts.get(section) + offset;
                const got = try file.read_at(buffer[0..wanted], start);
                if (got != wanted) return error.FileChanged;
            },
            .memory => |sections| {
                const bytes = sections.get(section);
                assert(bytes.len == size);
                @memcpy(buffer[0..wanted], bytes[@intCast(offset)..][0..wanted]);
            },
        }
        return buffer[0..wanted];
    }
};

/// Opens the binary behind `region` in process `pid`. `prefix` is `build_id.prefix_size` bytes
/// of scratch. The header and the path are copies in `arena`. `image` is the agent's own vDSO
/// image, if it has one: the [vdso] region is that, and must outlive the binary.
pub fn open(
    arena: std.mem.Allocator,
    pid: u32,
    region: *const Region,
    prefix: []u8,
    image: ?*const vdso.Image,
) !Binary {
    if (std.mem.eql(u8, region.path, vdso.path)) return open_vdso(arena, region, image);
    if (region.path.len == 0 or region.path[0] != '/') return error.NotAFile;
    const id = region.build_id orelse return error.NoBuildId;

    var file = try mapped_file.open(pid, region, prefix);
    errdefer file.deinit();

    // Only the headers and the section names: the symbol sections are streamed later.
    var loaded = try elf_file.load(&file, &.{}, 0);
    defer loaded.deinit();
    const layout = try layout_read(arena, id, region.path, loaded.bytes);
    return .{ .header = layout.header, .starts = layout.starts, .origin = .{ .file = file } };
}

/// The target's vDSO is the agent's own image, if their sizes agree (see target/vdso.zig). It
/// is read from memory: no file, no copy.
fn open_vdso(
    arena: std.mem.Allocator,
    region: *const Region,
    image_found: ?*const vdso.Image,
) !Binary {
    const image = image_found orelse return error.NoVdso;
    if (!image.matches(region.end - region.start)) return error.NoVdso;
    const id = image.build_id orelse return error.NoBuildId;
    // The region's ID was given from this image (regions.vdso_mark).
    if (region.build_id) |expected| {
        if (!std.mem.eql(u8, expected, id)) return error.WrongFile;
    }

    var layout = try layout_read(arena, id, vdso.path, image.bytes);
    // `layout_read` checked that every section lies inside the image.
    var sections = std.EnumArray(Section, []const u8).initFill(&.{});
    for (std.enums.values(Section)) |section| {
        const start: usize = @intCast(layout.starts.get(section));
        const size: usize = @intCast(layout.header.sizes.get(section));
        sections.set(section, image.bytes[start..][0..size]);
    }
    // Its stripped symbols, written from its stubs: the code that runs gets a name.
    if (try vdso_symbols.symbols(arena, image.bytes)) |written| {
        sections.set(.symtab, written.symtab);
        sections.set(.strtab, written.strtab);
        layout.header.sizes.set(.symtab, written.symtab.len);
        layout.header.sizes.set(.strtab, written.strtab.len);
    }
    return .{ .header = layout.header, .starts = layout.starts, .origin = .{ .memory = sections } };
}

/// The running kernel as a binary: its symbols, read from /proc/kallsyms as distances from
/// `_text` (kernel_symbols.zig), under `id`, its identity for this boot. The symbols are in
/// `arena` and must outlive the binary.
pub fn kernel_binary(
    arena: std.mem.Allocator,
    id: []const u8,
    symbols: *const kernel_symbols.Symbols,
) !Binary {
    var sizes = std.EnumArray(Section, u64).initFill(0);
    sizes.set(.symtab, symbols.symtab.len);
    sizes.set(.strtab, symbols.strtab.len);
    var sections = std.EnumArray(Section, []const u8).initFill(&.{});
    sections.set(.symtab, symbols.symtab);
    sections.set(.strtab, symbols.strtab);
    return .{
        .header = .{
            .build_id = try arena.dupe(u8, id),
            .path = kernel_symbols.path,
            .segments = try arena.dupe(elf.Segment, &.{kernel_symbols.segment}),
            .sizes = sizes,
        },
        .starts = .initFill(0),
        .origin = .{ .memory = sections },
    };
}

const Layout = struct {
    header: Header,
    starts: std.EnumArray(Section, u64),
};

/// `bytes` is an ELF file with at least its headers, as long as the file.
fn layout_read(
    arena: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    bytes: []const u8,
) !Layout {
    var segments: [segments_max]elf.Segment = undefined;
    const segments_count = try elf.segments_executable(bytes, &segments);

    var layout = Layout{
        .header = .{
            .build_id = try arena.dupe(u8, id),
            .path = try arena.dupe(u8, path),
            .segments = try arena.dupe(elf.Segment, segments[0..segments_count]),
            .sizes = .initFill(0),
        },
        .starts = .initFill(0),
    };
    for (std.enums.values(Section)) |section| {
        const found = (elf.find(bytes, section.name()) catch return error.NotElf) orelse continue;
        // Sections that hold nothing in the file, or point outside it, count as absent.
        const content = elf.bytes_of(bytes, found) orelse continue;
        layout.header.sizes.set(section, content.len);
        layout.starts.set(section, found.offset);
    }
    return layout;
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const process = @import("../os/process.zig");

fn region_test(path: []const u8, id: ?[]const u8) Region {
    return .{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = path,
        .build_id = id,
    };
}

/// A whole section, read in chunks of `chunk_bytes`.
fn section_read_all(
    arena: std.mem.Allocator,
    binary: *const Binary,
    section: Section,
    chunk_bytes: usize,
) ![]const u8 {
    const buffer = try arena.alloc(u8, chunk_bytes);
    var list: std.ArrayList(u8) = .empty;
    var offset: u64 = 0;
    while (offset < binary.header.sizes.get(section)) {
        const chunk = try binary.read(section, offset, buffer);
        try testing.expect(chunk.len > 0);
        try list.appendSlice(arena, chunk);
        offset += chunk.len;
    }
    try testing.expectEqual(binary.header.sizes.get(section), list.items.len);
    return list.items;
}

test "the vDSO is a binary: its header, and its dynamic symbols in small chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();

    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    const id = image.build_id orelse return error.SkipZigTest;
    const region = Region{
        .start = 0x7000,
        .end = 0x7000 + image.bytes.len,
        .offset = 0,
        .inode = 0,
        .path = vdso.path,
        .build_id = id,
    };

    var prefix: [build_id.prefix_size]u8 = undefined;
    var binary = try open(arena.allocator(), pid, &region, &prefix, &image);
    defer binary.deinit();

    try testing.expectEqualSlices(u8, id, binary.header.build_id);
    try testing.expectEqualStrings(vdso.path, binary.header.path);
    try testing.expect(binary.header.segments.len >= 1);
    const dynsym_size = binary.header.sizes.get(.dynsym);
    try testing.expect(dynsym_size > 0 and dynsym_size % 24 == 0);

    const dynstr = try section_read_all(arena.allocator(), &binary, .dynstr, 7);
    try testing.expect(std.mem.indexOf(u8, dynstr, "__vdso_clock_gettime") != null);

    // A [vdso] of another size is not the agent's own.
    var other = region;
    other.end += 4096;
    try testing.expectError(error.NoVdso, open(arena.allocator(), pid, &other, &prefix, &image));
    // Without an image of its own, the agent has nothing to send for a [vdso].
    try testing.expectError(error.NoVdso, open(arena.allocator(), pid, &region, &prefix, null));
}

test "a system binary: chunks of any size give the same bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prefix: [build_id.prefix_size]u8 = undefined;
    const pid = process.current_pid();

    var file = try mapped_file.open(pid, &region_test("/bin/sh", null), &prefix);
    const prefix_read = try file.read_at(&prefix, 0);
    file.deinit();
    const id = build_id.from_prefix(prefix[0..prefix_read]) orelse return error.SkipZigTest;

    var binary = try open(arena.allocator(), pid, &region_test("/bin/sh", id), &prefix, null);
    defer binary.deinit();
    try testing.expect(binary.header.segments.len >= 1);
    const dynsym_size = binary.header.sizes.get(.dynsym);
    try testing.expect(dynsym_size > 0 and dynsym_size % 24 == 0);

    const small = try section_read_all(arena.allocator(), &binary, .dynsym, 100);
    const large = try section_read_all(arena.allocator(), &binary, .dynsym, 1 << 20);
    try testing.expectEqualSlices(u8, small, large);
    // Past the end there is nothing.
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try binary.read(.dynsym, dynsym_size, &buffer)).len);
}

test "regions without a file or without an identity are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prefix: [build_id.prefix_size]u8 = undefined;
    const pid = process.current_pid();

    const anonymous = region_test("", null);
    const gpa = arena.allocator();
    try testing.expectError(error.NotAFile, open(gpa, pid, &anonymous, &prefix, null));
    const no_id = region_test("/bin/sh", null);
    try testing.expectError(error.NoBuildId, open(gpa, pid, &no_id, &prefix, null));
}

test "Header.clone copies the identity, the segments and the sizes" {
    const segments = [_]Header.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x200 }};
    var sizes = std.EnumArray(Section, u64).initFill(0);
    sizes.set(.dynsym, 240);
    const original = Header{
        .build_id = "\x01\x02\x03\x04",
        .path = "/usr/lib/libx.so",
        .segments = &segments,
        .sizes = sizes,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try original.clone(arena.allocator());

    try testing.expectEqualSlices(u8, original.build_id, copy.build_id);
    try testing.expectEqual(@as(u64, 0x401000), copy.segments[0].vaddr);
    try testing.expectEqual(@as(u64, 240), copy.sizes.get(.dynsym));
    try testing.expectEqual(@as(u64, 0), copy.sizes.get(.symtab));
    try testing.expect(copy.segments.ptr != original.segments.ptr);
}
