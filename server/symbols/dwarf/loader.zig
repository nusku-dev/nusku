//! The DWARF sections of an ELF file, decompressed.

const std = @import("std");
const elf = @import("shared").elf;
const Sections = @import("builder.zig").Sections;

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
        const bytes = if (compressed) try elf.decompress(gpa, raw) else raw;
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
