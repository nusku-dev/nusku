//! Finds a function by name in the files a process maps: where it starts in its file, so a
//! probe can be put there.

const std = @import("std");
const shared = @import("shared");
const elf_file = @import("../../elf/elf.zig").file;
const process = @import("../../os/os.zig").process;
const Region = @import("../../target/target.zig").Region;

const elf = shared.elf;
const File = shared.File;

pub const Error = error{
    OutOfMemory,
    FunctionNotFound,
    FunctionAmbiguous,
    GoProgram,
};

pub const Found = struct {
    /// The file as the process maps it.
    path: []const u8,
    /// Where the function starts in that file.
    offset: u64,
    size: u64,
};

const sym_bytes = 24;
const stt_func = 2;
const stt_gnu_ifunc = 10;
const read_max = 512 * 1024 * 1024;
const debug_root = "/usr/lib/debug/.build-id/";
const symbol_sections = [_][]const u8{ ".symtab", ".strtab", ".dynsym", ".dynstr" };

/// With `module`, only the file with that path or that file name is searched.
pub fn find(
    arena: std.mem.Allocator,
    pid: u32,
    regions: []const Region,
    module: ?[]const u8,
    name: []const u8,
) Error!Found {
    var found: ?Found = null;
    var searched: std.ArrayList([]const u8) = .empty;
    for (regions) |*region| {
        if (region.path.len == 0 or region.path[0] != '/') continue;
        if (module) |wanted| if (!module_matches(region.path, wanted)) continue;
        if (seen(searched.items, region.path)) continue;
        try searched.append(arena, region.path);
        const hit = try file_find(arena, pid, region, name) orelse continue;
        if (found != null) return error.FunctionAmbiguous;
        found = hit;
    }
    return found orelse error.FunctionNotFound;
}

fn module_matches(path: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, path, wanted)) return true;
    return std.mem.eql(u8, std.fs.path.basename(path), wanted);
}

fn seen(paths: []const []const u8, path: []const u8) bool {
    for (paths) |other| if (std.mem.eql(u8, other, path)) return true;
    return false;
}

fn file_find(
    arena: std.mem.Allocator,
    pid: u32,
    region: *const Region,
    name: []const u8,
) Error!?Found {
    var file = process.mapping_open(pid, region.path, region.start, region.end, region.inode) catch
        return null;
    defer file.deinit();
    var loaded = elf_file.load(&file, &symbol_sections, read_max) catch return null;
    defer loaded.deinit();
    const bytes = loaded.bytes;

    const symbol = symbol_find(bytes, ".symtab", ".strtab", name) orelse
        symbol_find(bytes, ".dynsym", ".dynstr", name) orelse
        debug_find(arena, region.build_id, name) orelse
        return null;
    if ((elf.find(bytes, ".gopclntab") catch null) != null) return error.GoProgram;
    const offset = offset_of(bytes, symbol.vaddr) orelse return null;
    return .{ .path = region.path, .offset = offset, .size = symbol.size };
}

const Symbol = struct { vaddr: u64, size: u64 };

fn symbol_find(
    bytes: []const u8,
    table: []const u8,
    names: []const u8,
    name: []const u8,
) ?Symbol {
    const table_section = (elf.find(bytes, table) catch return null) orelse return null;
    const names_section = (elf.find(bytes, names) catch return null) orelse return null;
    const symbols = elf.bytes_of(bytes, table_section) orelse return null;
    const strings = elf.bytes_of(bytes, names_section) orelse return null;
    var at: usize = 0;
    while (at + sym_bytes <= symbols.len) : (at += sym_bytes) {
        const entry = symbols[at..][0..sym_bytes];
        const kind = entry[4] & 0xf;
        if (kind != stt_func and kind != stt_gnu_ifunc) continue;
        const section_index = std.mem.readInt(u16, entry[6..8], .little);
        const vaddr = std.mem.readInt(u64, entry[8..16], .little);
        if (section_index == 0 or vaddr == 0) continue;
        const name_at = std.mem.readInt(u32, entry[0..4], .little);
        if (name_at >= strings.len) continue;
        const found = std.mem.sliceTo(strings[name_at..], 0);
        if (!name_matches(found, name)) continue;
        return .{ .vaddr = vaddr, .size = std.mem.readInt(u64, entry[16..24], .little) };
    }
    return null;
}

/// `memcpy@GLIBC_2.14` and `memcpy@@GLIBC_2.14` are `memcpy`.
fn name_matches(found: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, found, name)) return false;
    return found.len == name.len or found[name.len] == '@';
}

/// The symbols of a stripped binary, from its debug package; their addresses are the binary's.
fn debug_find(arena: std.mem.Allocator, build_id: ?[]const u8, name: []const u8) ?Symbol {
    const id = build_id orelse return null;
    if (id.len < 2 or id.len > 64) return null;
    var digits: [128]u8 = undefined;
    for (id, 0..) |byte, i| {
        digits[2 * i] = "0123456789abcdef"[byte >> 4];
        digits[2 * i + 1] = "0123456789abcdef"[byte & 0xf];
    }
    const text = digits[0 .. 2 * id.len];
    const path = std.fmt.allocPrintSentinel(arena, "{s}{s}/{s}.debug", .{
        debug_root,
        text[0..2],
        text[2..],
    }, 0) catch return null;
    var file = File.open(path) catch return null;
    defer file.deinit();
    var loaded = elf_file.load(&file, &symbol_sections, read_max) catch return null;
    defer loaded.deinit();
    return symbol_find(loaded.bytes, ".symtab", ".strtab", name);
}

fn offset_of(bytes: []const u8, vaddr: u64) ?u64 {
    var segments: [16]elf.Segment = undefined;
    const count = elf.segments_executable(bytes, &segments) catch return null;
    for (segments[0..count]) |segment| {
        if (vaddr >= segment.vaddr and vaddr < segment.vaddr + segment.filesz) {
            return vaddr - segment.vaddr + segment.offset;
        }
    }
    return null;
}

const testing = std.testing;

test "a function of this process is found where the process runs it" {
    const target = @import("../../target/target.zig");
    const child_process = @import("../../testing/process.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pid = process.current_pid();
    var own = try target.Target.init(testing.allocator, pid);
    defer own.deinit(testing.allocator);

    const name = "testing.process.probed_function";
    const found = try find(arena.allocator(), pid, own.regions, null, name);
    const address = @intFromPtr(&child_process.probed_function);
    const region = for (own.regions) |r| {
        if (address >= r.start and address < r.end) break r;
    } else return error.NotMapped;
    try testing.expectEqualStrings(region.path, found.path);
    try testing.expectEqual(address - region.start + region.offset, found.offset);
    try testing.expect(found.size > 0);

    const module = std.fs.path.basename(region.path);
    _ = try find(arena.allocator(), pid, own.regions, module, name);
    const missing = find(arena.allocator(), pid, own.regions, "no-such-module", name);
    try testing.expectError(error.FunctionNotFound, missing);
    const unknown = find(arena.allocator(), pid, own.regions, null, "no_such_function_nusku");
    try testing.expectError(error.FunctionNotFound, unknown);
}

test "a versioned name matches its plain name, and only that" {
    try testing.expect(name_matches("memcpy@GLIBC_2.14", "memcpy"));
    try testing.expect(name_matches("memcpy@@GLIBC_2.14", "memcpy"));
    try testing.expect(name_matches("memcpy", "memcpy"));
    try testing.expect(!name_matches("memcpy_chk", "memcpy"));
    try testing.expect(!name_matches("mem", "memcpy"));
}
