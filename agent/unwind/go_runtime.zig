//! Where the Go runtime keeps a goroutine's place, read from the binary's DWARF: the field
//! offsets of runtime.g, runtime.m and runtime.gobuf. With them, a stack walk that reaches
//! Go's switch to its system stack can go on from where the goroutine was.

const std = @import("std");
const shared = @import("shared");
const wire = @import("wire.zig");

const dwarf = shared.dwarf;
const elf = shared.elf;

const Reader = dwarf.Reader;
const decoder = dwarf.decoder;

pub const Offsets = wire.GoOffsets;

/// The sections the offsets are read from, besides those read for unwinding.
pub const sections = [_][]const u8{ ".debug_info", ".debug_abbrev", ".debug_str" };

const tag_structure = 0x13;
const tag_member = 0x0d;
const at_name = 0x03;
const at_member_location = 0x38;

const Struct = enum { g, m, gobuf };

const Field = struct { owner: Struct, name: []const u8, slot: []const u8 };

const fields = [_]Field{
    .{ .owner = .g, .name = "m", .slot = "g_m" },
    .{ .owner = .g, .name = "sched", .slot = "g_sched" },
    .{ .owner = .m, .name = "g0", .slot = "m_g0" },
    .{ .owner = .m, .name = "curg", .slot = "m_curg" },
    .{ .owner = .m, .name = "vdsoSP", .slot = "m_vdso_sp" },
    .{ .owner = .m, .name = "vdsoPC", .slot = "m_vdso_pc" },
    .{ .owner = .gobuf, .name = "sp", .slot = "gobuf_sp" },
    .{ .owner = .gobuf, .name = "pc", .slot = "gobuf_pc" },
    .{ .owner = .gobuf, .name = "bp", .slot = "gobuf_bp" },
};

/// Null when the binary has no DWARF (built with -ldflags=-w), or the layout is not found.
pub fn offsets_of(gpa: std.mem.Allocator, file: []const u8) ?Offsets {
    const info = section_load(gpa, file, ".debug_info") orelse return null;
    defer if (info.owned) gpa.free(info.bytes);
    const abbrev = section_load(gpa, file, ".debug_abbrev") orelse return null;
    defer if (abbrev.owned) gpa.free(abbrev.bytes);
    const strings = section_load(gpa, file, ".debug_str");
    defer if (strings) |found| if (found.owned) gpa.free(found.bytes);

    var found = Found{};
    var r = Reader{ .bytes = info.bytes };
    while (!r.done() and found.count < fields.len) {
        const unit = unit_header(&r) catch return null;
        r.at = @intCast(unit.end);
        if (unit.dies == 0) continue;
        const text = if (strings) |section| section.bytes else &.{};
        unit_walk(gpa, &found, info.bytes, abbrev.bytes, text, unit) catch continue;
    }
    if (found.count < fields.len) return null;
    var offsets = found.offsets;
    offsets.known = 1;
    return offsets;
}

const Found = struct {
    offsets: Offsets = .{},
    seen: [fields.len]bool = @splat(false),
    count: usize = 0,

    fn put(found: *Found, owner: Struct, name: []const u8, offset: u64) void {
        const value = std.math.cast(u16, offset) orelse return;
        inline for (fields, 0..) |field, index| {
            const matches = field.owner == owner and std.mem.eql(u8, field.name, name);
            if (matches and !found.seen[index]) {
                @field(found.offsets, field.slot) = value;
                found.seen[index] = true;
                found.count += 1;
            }
        }
    }
};

const Section = struct { bytes: []const u8, owned: bool };

fn section_load(gpa: std.mem.Allocator, file: []const u8, name: []const u8) ?Section {
    const section = (elf.find(file, name) catch return null) orelse return null;
    const raw = elf.bytes_of(file, section) orelse return null;
    if (section.flags & elf.shf_compressed == 0) return .{ .bytes = raw, .owned = false };
    const bytes = elf.decompress(gpa, raw) catch return null;
    return .{ .bytes = bytes, .owned = true };
}

const Unit = struct { end: u64, dies: u64, abbrev_offset: u64, format: decoder.Unit };

fn unit_header(r: *Reader) !Unit {
    var wide = false;
    const length = try r.length(&wide);
    const end = std.math.add(u64, r.at, length) catch return error.Malformed;
    if (end > r.bytes.len) return error.Malformed;
    const version = try r.int(u16);
    var unit = Unit{
        .end = end,
        .dies = 0,
        .abbrev_offset = 0,
        .format = .{ .version = version, .wide = wide, .address_size = 8 },
    };
    if (version < 2 or version > 5) return unit;
    if (version >= 5) {
        _ = try r.int(u8);
        unit.format.address_size = try r.int(u8);
        unit.abbrev_offset = try r.offset(wide);
    } else {
        unit.abbrev_offset = try r.offset(wide);
        unit.format.address_size = try r.int(u8);
    }
    unit.dies = r.at;
    return unit;
}

fn unit_walk(
    gpa: std.mem.Allocator,
    found: *Found,
    info: []const u8,
    abbrev_section: []const u8,
    strings: []const u8,
    unit: Unit,
) !void {
    var abbrevs: dwarf.Abbrevs = undefined;
    try abbrevs.init(gpa, abbrev_section, unit.abbrev_offset);
    defer abbrevs.deinit(gpa);

    var r: Reader = undefined;
    r.init(info[0..@intCast(unit.end)], @intCast(unit.dies));

    var depth: u32 = 0;
    var current: ?Struct = null;
    var current_depth: u32 = 0;
    while (!r.done() and found.count < fields.len) {
        const code = try r.uleb();
        if (code == 0) {
            if (depth == 0) return;
            depth -= 1;
            if (current != null and depth <= current_depth) current = null;
            continue;
        }
        const abbrev = abbrevs.find(code) orelse return error.Malformed;
        var name: ?[]const u8 = null;
        var location: ?u64 = null;
        for (abbrev.attrs) |attr| {
            const value = try decoder.value_read(&r, attr.form, attr.implicit, unit.format);
            if (attr.name == at_name) name = switch (value) {
                .string => |text| text,
                .strp => |at| decoder.string_at(strings, at),
                else => null,
            };
            if (attr.name == at_member_location) location = value.number();
        }
        if (abbrev.tag == tag_structure and abbrev.children) {
            if (struct_of(name)) |kind| {
                current = kind;
                current_depth = depth;
            }
        } else if (abbrev.tag == tag_member and current != null and depth == current_depth + 1) {
            if (name != null and location != null) found.put(current.?, name.?, location.?);
        }
        if (abbrev.children) depth += 1;
    }
}

fn struct_of(name: ?[]const u8) ?Struct {
    const text = name orelse return null;
    if (std.mem.eql(u8, text, "runtime.g")) return .g;
    if (std.mem.eql(u8, text, "runtime.m")) return .m;
    if (std.mem.eql(u8, text, "runtime.gobuf")) return .gobuf;
    return null;
}

const testing = std.testing;

test "the Go test program: the runtime's layout is found in its DWARF" {
    const File = shared.File;
    var file = File.open("testing/out/go-app") catch return error.SkipZigTest;
    defer file.deinit();
    const size: usize = @intCast(try file.size_bytes());
    const bytes = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(bytes);
    _ = try file.read_at(bytes, 0);

    const offsets = offsets_of(testing.allocator, bytes) orelse return error.NotFound;
    try testing.expectEqual(@as(u16, 1), offsets.known);
    try testing.expectEqual(@as(u16, 48), offsets.g_m);
    try testing.expectEqual(@as(u16, 0), offsets.m_g0);
    try testing.expectEqual(@as(u16, 0), offsets.gobuf_sp);
    try testing.expectEqual(@as(u16, 8), offsets.gobuf_pc);
    try testing.expect(offsets.m_curg > 0 and offsets.m_vdso_sp > 0 and offsets.m_vdso_pc > 0);
}
