//! What a stripped binary lacks, from its separate debug file: symbols and DWARF, fetched
//! with debuginfod. A debug file installed on the profiled machine is the agent's to send,
//! with the binary: the server never looks on its own disk, which may be another machine's.
const std = @import("std");
const shared = @import("shared");
const log = @import("../log.zig").server;
const dwarf_load = @import("dwarf/dwarf.zig").dwarf_load;
const Library = @import("../os/os.zig").Library;
const elf = shared.elf;

const assert = std.debug.assert;

const file_bytes_max = 128 * 1024 * 1024;
const sym_bytes = 24;
const fetch_seconds_max = 15;

pub const Source = enum { debuginfod };

pub const Info = struct {
    symtab: []const u8 = &.{},
    strtab: []const u8 = &.{},
    dwarf: ?dwarf_load.Loaded = null,
    owned: [2]?[]u8 = .{ null, null },
    source: Source,

    pub fn deinit(info: *Info, gpa: std.mem.Allocator) void {
        if (info.dwarf) |*loaded| loaded.deinit(gpa);
        for (info.owned) |maybe| if (maybe) |bytes| gpa.free(bytes);
        info.* = undefined;
    }
};

/// Takes `bytes`, a whole debug file; what it does not hold stays empty.
fn from_bytes(gpa: std.mem.Allocator, bytes: []u8, source: Source) ?Info {
    var found = Info{ .source = source, .owned = .{ bytes, null } };
    if (section_of(bytes, ".symtab")) |symtab| {
        if (symtab.len > 0 and symtab.len % sym_bytes == 0) {
            found.symtab = symtab;
            found.strtab = section_of(bytes, ".strtab") orelse &.{};
        }
    }
    if (section_of(bytes, ".debug_info") != null) {
        found.dwarf = dwarf_load.from_elf(gpa, bytes) catch null;
    }
    if (found.symtab.len == 0 and found.dwarf == null) {
        found.deinit(gpa);
        return null;
    }
    return found;
}

pub const Finder = struct {
    network: bool,
    library: ?Library = null,
    library_tried: bool = false,

    pub fn init(network: bool) Finder {
        return .{ .network = network };
    }

    pub fn deinit(finder: *Finder) void {
        if (finder.library) |*library| library.deinit();
        finder.* = undefined;
    }

    pub fn find(finder: *Finder, gpa: std.mem.Allocator, build_id: []const u8) ?Info {
        if (build_id.len == 0) return null;
        if (!finder.network) return null;
        const library = finder.library_get() orelse return null;

        if (library.debuginfo(gpa, build_id)) |bytes| {
            if (from_bytes(gpa, bytes, .debuginfod)) |info| return info;
        }
        const symtab = library.section(gpa, build_id, ".symtab") orelse return null;
        if (symtab.len == 0 or symtab.len % sym_bytes != 0) {
            gpa.free(symtab);
            return null;
        }

        const strtab = library.section(gpa, build_id, ".strtab") orelse {
            gpa.free(symtab);
            return null;
        };

        return .{
            .symtab = symtab,
            .strtab = strtab,
            .owned = .{ symtab, strtab },
            .source = .debuginfod,
        };
    }

    fn library_get(finder: *Finder) ?*Library {
        if (!finder.library_tried) {
            finder.library_tried = true;
            finder.library = Library.init();
        }
        return if (finder.library) |*library| library else null;
    }
};

fn section_of(bytes: []const u8, name: []const u8) ?[]const u8 {
    const found = (elf.find(bytes, name) catch return null) orelse return null;
    return elf.bytes_of(bytes, found);
}

const testing = std.testing;

test "without the network, nothing is looked for: not even on this machine's disk" {
    var finder = Finder.init(false);
    defer finder.deinit();
    try testing.expect(finder.find(testing.allocator, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }) == null);
}
