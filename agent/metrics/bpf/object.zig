//! Reads what the loader needs of a bpfel ELF object.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ NotElf, Unsupported, Truncated, SectionNotFound, SymbolNotFound };

const machine_bpf = 247;
const section_type_symbol_table = 2;
const section_type_relocations = 9;
const symbol_binding_global = 1;

const elf_header_size = 64;
const section_header_size_min = 64;
const symbol_size = 24;
const relocation_size = 16;
const map_definition_size = 16;

pub const Section = struct {
    index: u32,
    name: u32,
    kind: u32,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
};

pub const Symbol = struct {
    section: u32,
    value: u64,
    size: u64,
};

pub const Relocation = struct {
    offset: u64,
    kind: u32,
    target: Symbol,
};

pub const MapDefinition = struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
};

pub const Object = struct {
    bytes: []const u8,
    section_headers_offset: u64,
    section_header_size: u64,
    section_count: u32,
    section_names_index: u32,

    pub fn init(bytes: []const u8) Error!Object {
        if (bytes.len < elf_header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
        if (bytes[4] != 2) return error.Unsupported;
        if (bytes[5] != 1) return error.Unsupported;
        if (try int_read(u16, bytes, 18) != machine_bpf) return error.Unsupported;

        const object = Object{
            .bytes = bytes,
            .section_headers_offset = try int_read(u64, bytes, 40),
            .section_header_size = try int_read(u16, bytes, 58),
            .section_count = try int_read(u16, bytes, 60),
            .section_names_index = try int_read(u16, bytes, 62),
        };
        if (object.section_header_size < section_header_size_min) return error.Unsupported;
        if (object.section_names_index >= object.section_count) return error.Unsupported;

        const table_size = std.math.mul(u64, object.section_count, object.section_header_size) catch
            return error.Truncated;
        const table_end = std.math.add(u64, object.section_headers_offset, table_size) catch
            return error.Truncated;
        if (table_end > bytes.len) return error.Truncated;
        return object;
    }

    pub fn section_find(object: *const Object, name: []const u8) Error!Section {
        assert(name.len > 0);
        const names = try object.section_bytes(try object.section_at(object.section_names_index));

        var index: u32 = 0;
        while (index < object.section_count) : (index += 1) {
            const section = try object.section_at(index);
            if (section.name >= names.len) continue;
            if (std.mem.eql(u8, std.mem.sliceTo(names[section.name..], 0), name)) return section;
        }
        return error.SectionNotFound;
    }

    pub fn symbol_find(object: *const Object, name: []const u8) Error!Symbol {
        assert(name.len > 0);
        var index: u32 = 0;
        while (index < object.section_count) : (index += 1) {
            const table = try object.section_at(index);
            if (table.kind != section_type_symbol_table) continue;
            const symbols = try object.section_bytes(table);
            const names = try object.section_bytes(try object.section_at(table.link));

            var offset: u64 = 0;
            while (offset + symbol_size <= symbols.len) : (offset += symbol_size) {
                if (symbols[@intCast(offset + 4)] >> 4 != symbol_binding_global) continue;
                const name_offset = try int_read(u32, symbols, offset);
                if (name_offset >= names.len) continue;
                if (!std.mem.eql(u8, std.mem.sliceTo(names[name_offset..], 0), name)) continue;
                return try symbol_at(symbols, offset);
            }
        }
        return error.SymbolNotFound;
    }

    pub fn section_bytes(object: *const Object, section: Section) Error![]const u8 {
        const end = std.math.add(u64, section.offset, section.size) catch return error.Truncated;
        if (end > object.bytes.len) return error.Truncated;
        return object.bytes[@intCast(section.offset)..@intCast(end)];
    }

    pub fn relocations(object: *const Object, program: Section) Error!RelocationIterator {
        var index: u32 = 0;
        while (index < object.section_count) : (index += 1) {
            const section = try object.section_at(index);
            if (section.kind != section_type_relocations) continue;
            if (section.info != program.index) continue;
            return .{
                .entries = try object.section_bytes(section),
                .symbols = try object.section_bytes(try object.section_at(section.link)),
            };
        }
        return .{ .entries = &.{}, .symbols = &.{} };
    }

    pub fn map_definition(object: *const Object, name: []const u8) Error!MapDefinition {
        const symbol = try object.symbol_find(name);
        const maps = try object.section_find(".maps");
        if (symbol.section != maps.index) return error.Unsupported;
        if (symbol.size != map_definition_size) return error.Unsupported;

        const bytes = try object.section_bytes(maps);
        return .{
            .map_type = try int_read(u32, bytes, symbol.value),
            .key_size = try int_read(u32, bytes, symbol.value + 4),
            .value_size = try int_read(u32, bytes, symbol.value + 8),
            .max_entries = try int_read(u32, bytes, symbol.value + 12),
        };
    }

    fn section_at(object: *const Object, index: u32) Error!Section {
        if (index >= object.section_count) return error.SectionNotFound;
        const header = object.section_headers_offset + index * object.section_header_size;
        return .{
            .index = index,
            .name = try int_read(u32, object.bytes, header),
            .kind = try int_read(u32, object.bytes, header + 4),
            .offset = try int_read(u64, object.bytes, header + 24),
            .size = try int_read(u64, object.bytes, header + 32),
            .link = try int_read(u32, object.bytes, header + 40),
            .info = try int_read(u32, object.bytes, header + 44),
        };
    }
};

pub const RelocationIterator = struct {
    entries: []const u8,
    symbols: []const u8,
    position: u64 = 0,

    pub fn next(iterator: *RelocationIterator) Error!?Relocation {
        if (iterator.position + relocation_size > iterator.entries.len) return null;
        const offset = try int_read(u64, iterator.entries, iterator.position);
        const info = try int_read(u64, iterator.entries, iterator.position + 8);
        iterator.position += relocation_size;

        const symbol_offset = std.math.mul(u64, info >> 32, symbol_size) catch
            return error.Truncated;
        return .{
            .offset = offset,
            .kind = @truncate(info),
            .target = try symbol_at(iterator.symbols, symbol_offset),
        };
    }
};

fn symbol_at(symbols: []const u8, offset: u64) Error!Symbol {
    return .{
        .section = try int_read(u16, symbols, offset + 6),
        .value = try int_read(u64, symbols, offset + 8),
        .size = try int_read(u64, symbols, offset + 16),
    };
}

fn int_read(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    const end = std.math.add(u64, offset, @sizeOf(T)) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

const testing = std.testing;

test "the cpu object holds its program, its license and every map it declares" {
    const object = try Object.init(@embedFile("cpu_bpf"));

    const program = try object.section_find("perf_event/cpu_sample");
    const code = try object.section_bytes(program);
    try testing.expect(code.len > 16);
    try testing.expectEqual(@as(usize, 0), code.len % 8);

    const license = try object.section_bytes(try object.section_find("license"));
    try testing.expectEqualStrings("GPL", std.mem.sliceTo(license, 0));

    const ring = try object.map_definition("cpu_records");
    try testing.expectEqual(@as(u32, 27), ring.map_type);
    try testing.expectEqual(@as(u32, 0), ring.key_size);
}

test "a symbol or section that is not there is an error, not a crash" {
    const object = try Object.init(@embedFile("cpu_bpf"));
    try testing.expectError(error.SectionNotFound, object.section_find(".no_such_section"));
    try testing.expectError(error.SymbolNotFound, object.symbol_find("no_such_symbol"));
    try testing.expectError(error.SymbolNotFound, object.symbol_find("cpu.bpf.cpu_config"));
}

test "objects that are not BPF ELF files are refused" {
    try testing.expectError(error.Truncated, Object.init("short"));
    try testing.expectError(error.NotElf, Object.init(&([_]u8{0} ** 64)));

    var bytes: [64]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    std.mem.writeInt(u16, bytes[18..20], 62, .little);
    try testing.expectError(error.Unsupported, Object.init(&bytes));

    std.mem.writeInt(u16, bytes[18..20], machine_bpf, .little);
    std.mem.writeInt(u16, bytes[58..60], 64, .little);
    std.mem.writeInt(u16, bytes[60..62], 4, .little);
    std.mem.writeInt(u64, bytes[40..48], 1 << 40, .little);
    try testing.expectError(error.Truncated, Object.init(&bytes));
}
