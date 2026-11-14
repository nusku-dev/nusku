//! The DWARF sections of an ELF file, decompressed.

const std = @import("std");
const elf = @import("shared").elf;
const Sections = @import("builder.zig").Sections;

const chdr_bytes = 24;
const elfcompress_zlib = 1;
const elfcompress_zstd = 2;
const section_bytes_max = 1024 * 1024 * 1024;

pub const Error = error{ OutOfMemory, Malformed };

pub const names = .{
    .{ "info", ".debug_info" },
    .{ "abbrev", ".debug_abbrev" },
    .{ "line", ".debug_line" },
    .{ "str", ".debug_str" },
    .{ "line_str", ".debug_line_str" },
    .{ "addr", ".debug_addr" },
    .{ "str_offsets", ".debug_str_offsets" },
    .{ "ranges", ".debug_ranges" },
    .{ "rnglists", ".debug_rnglists" },
};

/// Sections that were decompressed are owned; the others point into the given bytes.
pub const Loaded = struct {
    sections: Sections = .{},
    owned: [names.len]?[]u8 = @splat(null),

    pub fn deinit(loaded: *Loaded, gpa: std.mem.Allocator) void {
        for (loaded.owned) |maybe| if (maybe) |bytes| gpa.free(bytes);
        loaded.* = undefined;
    }

    pub fn put(
        loaded: *Loaded,
        gpa: std.mem.Allocator,
        index: usize,
        raw: []const u8,
        compressed: bool,
    ) Error!void {
        const bytes = if (compressed) try decompress(gpa, raw) else raw;
        if (compressed) loaded.owned[index] = @constCast(bytes);
        inline for (names, 0..) |pair, i| {
            if (i == index) @field(loaded.sections, pair[0]) = bytes;
        }
    }
};

pub fn from_elf(gpa: std.mem.Allocator, file: []const u8) Error!Loaded {
    var loaded = Loaded{};
    errdefer loaded.deinit(gpa);
    inline for (names, 0..) |pair, index| {
        const found = elf.find(file, pair[1]) catch return error.Malformed;
        if (found) |section| {
            if (elf.bytes_of(file, section)) |raw| {
                try loaded.put(gpa, index, raw, section.flags & elf.shf_compressed != 0);
            }
        }
    }
    return loaded;
}

pub fn decompress(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (raw.len < chdr_bytes) return error.Malformed;
    const kind = std.mem.readInt(u32, raw[0..4], .little);
    const size = std.mem.readInt(u64, raw[8..16], .little);
    if (size == 0 or size > section_bytes_max) return error.Malformed;
    const out = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(out);
    var input: std.Io.Reader = .fixed(raw[chdr_bytes..]);
    switch (kind) {
        elfcompress_zlib => {
            const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(window);
            var flate: std.compress.flate.Decompress = .init(&input, .zlib, window);
            flate.reader.readSliceAll(out) catch return error.Malformed;
        },
        elfcompress_zstd => {
            const zstd_lib = std.compress.zstd;
            const window = try gpa.alloc(u8, zstd_lib.default_window_len + zstd_lib.block_size_max);
            defer gpa.free(window);
            var zstd: zstd_lib.Decompress = .init(&input, window, .{});
            zstd.reader.readSliceAll(out) catch return error.Malformed;
        },
        else => return error.Malformed,
    }
    return out;
}
