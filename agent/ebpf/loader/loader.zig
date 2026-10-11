const std = @import("std");
const parser = @import("../elf/parser.zig");
const meta = @import("../elf/metadata.zig");
const Map = @import("map.zig").Map;
const Program = @import("program.zig").Program;
const cError = @import("../libc/error.zig").Error;

pub const Error = parser.Error || cError || error{UnknownMap};

const ELF = parser.ELF;

/// A map we created, matched to its definition in the object by name.
pub const MapRef = struct {
    name: []const u8,
    map: Map,
};

const R_BPF_64_64: u32 = 1;
const LD_IMM64: u8 = 0x18; // the 16-byte "load 64-bit immediate" instruction
const BPF_PSEUDO_MAP_FD: u8 = 1;

pub const Loader = struct {
    elf: ELF,
    allocator: std.mem.Allocator,
    program: ?Program,

    pub fn init(allocator: std.mem.Allocator, elf: ELF) Loader {
        return .{ .allocator = allocator, .elf = elf, .program = null };
    }

    pub fn load(
        self: *Loader,
        kind: Program.Kind,
        section_name: []const u8,
        function_name: [:0]const u8,
        maps: []const MapRef,
    ) Error!c_int {
        const section = try self.elf.findSection(section_name);
        const func = try self.elf.findSymbol(function_name);
        const section_bytes = try self.elf.readSectionData(section);
        if (func.section != section.index or func.value != 0 or func.size != section_bytes.len) return error.Unsupported;
        if (section_bytes.len == 0 or section_bytes.len % 8 != 0) return error.Unsupported;

        // An 8-byte aligned copy: the kernel reads the instructions as structs
        const words = try self.allocator.alloc(u64, section_bytes.len / 8);
        defer self.allocator.free(words);
        const code = std.mem.sliceAsBytes(words);
        @memcpy(code, section_bytes);

        try self.patchMaps(section, code, maps);
        var log = std.mem.zeroes([64 * 1024]u8);

        const license = try self.elf.readSectionData(try self.elf.findSection("license"));

        const program = try Program.load(kind, function_name, code, license, &log);
        self.program = program;

        return program.fd;
    }

    pub fn deinit(self: *Loader) void {
        if (self.program) |*program| {
            program.deinit();
        }
        self.program = null;
    }

    /// Fills in the map descriptors in a copy of the program's code. For each relocation, the
    /// ld_imm64 instruction gets src_reg = BPF_PSEUDO_MAP_FD and the map's descriptor as its
    /// immediate. Only references to maps are supported: anything else (such as .rodata)
    /// makes this fail, so a kernel program that starts using it is caught here.
    pub fn patchMaps(
        self: Loader,
        program: parser.Section,
        code: []u8,
        maps: []const MapRef,
    ) Error!void {
        const maps_section = try self.elf.findSection(".maps");

        var it = try self.elf.relocationsFor(program);
        while (try it.next()) |reloc| {
            if (reloc.target.section != maps_section.index or reloc.kind != R_BPF_64_64) return error.Unsupported;
            if (reloc.offset + 16 > code.len or code[reloc.offset] != LD_IMM64) return error.Unsupported;

            // Before patching, the immediate holds the offset of the map's definition inside .maps.
            const imm = code[reloc.offset + 4 ..][0..4];
            const def_offset = std.mem.readInt(i32, imm, .little);

            const fd = try self.fdForOffset(maps, def_offset);
            // The register byte holds dst in the low nibble and src in the high nibble.
            code[reloc.offset + 1] = (code[reloc.offset + 1] & 0x0f) | (BPF_PSEUDO_MAP_FD << 4);
            std.mem.writeInt(i32, imm, fd, .little);
        }
    }

    fn fdForOffset(self: Loader, maps: []const MapRef, def_offset: i32) Error!c_int {
        for (maps) |m| {
            const symbol = try self.elf.findSymbol(m.name);
            if (def_offset >= 0 and symbol.value == @as(usize, @intCast(def_offset))) return m.map.fd;
        }
        return error.UnknownMap;
    }

    /// Creates one of the object's maps in the kernel, using the definition stored in the object
    pub fn createMap(self: Loader, name: [:0]const u8) Error!MapRef {
        const symbol = try self.elf.findSymbol(name);
        const maps = try self.elf.findSection(".maps");
        if (symbol.section != maps.index or symbol.size != 16) return error.Unsupported;

        const bytes = try self.elf.readSectionData(maps);
        const mapDef = try meta.MapDef.init(bytes, symbol);
        const map = try Map.create(name, .{
            .map_type = mapDef.map_type,
            .key_size = mapDef.key_size,
            .value_size = mapDef.value_size,
            .max_entries = mapDef.max_entries,
        });
        return .{ .name = name, .map = map };
    }
};

const testing = std.testing;

test "creates the three maps in the kernel" {
    const bytes = @embedFile("oncpu_bpf");
    const elf = try ELF.init(bytes);

    var loader = Loader.init(testing.allocator, elf);
    defer loader.deinit();

    const stacks = loader.createMap("stacks") catch |err| {
        if (err == error.PermissionDenied or err == error.NotSupported) {
            return error.SkipZigTest;
        }
        return err;
    };

    try testing.expect(stacks.map.fd >= 0);

    const counts = try loader.createMap("counts");
    try testing.expect(counts.map.fd >= 0);

    const target_pid = try loader.createMap("target_pid");
    try testing.expect(target_pid.map.fd >= 0);

    // The array map is the one we can round-trip a value through without a program.
    const key = std.mem.toBytes(@as(u32, 0));
    const value = std.mem.toBytes(@as(u32, 4242));

    try target_pid.map.update(&key, &value);

    var out: [4]u8 = undefined;

    try std.testing.expect(try target_pid.map.lookup(&key, &out));
    try std.testing.expectEqual(@as(u32, 4242), std.mem.bytesToValue(u32, &out));
}

test "patchMaps fills in the descriptors and touches nothing else" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const program = try elf.findSection("perf_event");
    const original = try elf.readSectionData(program);

    const code = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(code);

    const maps = [_]MapRef{
        .{ .name = "stacks", .map = Map{ .fd = 100, .key_size = 4, .value_size = 4 } },
        .{ .name = "counts", .map = Map{ .fd = 101, .key_size = 4, .value_size = 4 } },
        .{ .name = "target_pid", .map = Map{ .fd = 102, .key_size = 4, .value_size = 4 } },
    };

    var loader = Loader.init(testing.allocator, elf);
    defer loader.deinit();

    try loader.patchMaps(program, code, &maps);

    // Every relocated instruction now names the right descriptor.
    var patched_at: [32]usize = undefined;
    var n: usize = 0;
    var it = try elf.relocationsFor(program);
    while (try it.next()) |reloc| {
        patched_at[n] = reloc.offset;
        n += 1;

        const before = std.mem.readInt(i32, original[reloc.offset + 4 ..][0..4], .little);
        const expected: i32 = for (maps) |m| {
            if ((try elf.findSymbol(m.name)).value == before) break m.map.fd;
        } else return error.TestUnexpectedResult;

        try testing.expectEqual(@as(u8, 1), code[reloc.offset + 1] >> 4);
        try testing.expectEqual(original[reloc.offset + 1] & 0x0f, code[reloc.offset + 1] & 0x0f);
        try testing.expectEqual(expected, std.mem.readInt(i32, code[reloc.offset + 4 ..][0..4], .little));
    }
    try std.testing.expect(n >= 3);

    // Every other byte is exactly as the compiler wrote it.
    for (code, original, 0..) |got, want, b| {
        var patchable = false;
        for (patched_at[0..n]) |o| {
            if (b == o + 1 or (b >= o + 4 and b < o + 8)) patchable = true;
        }
        if (!patchable) try testing.expectEqual(want, got);
    }
}

test "patchMaps fails when a map is missing from the list" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const program = try elf.findSection("perf_event");

    const code = try std.testing.allocator.dupe(u8, try elf.readSectionData(program));
    defer testing.allocator.free(code);

    var loader = Loader.init(testing.allocator, elf);
    defer loader.deinit();

    const maps = [_]MapRef{
        .{ .name = "stacks", .map = Map{ .fd = 101, .value_size = 4, .key_size = 4 } },
        .{ .name = "target_pid", .map = Map{ .fd = 102, .value_size = 4, .key_size = 4 } },
    };
    try testing.expectError(error.UnknownMap, loader.patchMaps(program, code, &maps));
}

test "a rejected program comes with the verifier's explanation (needs root, skipped otherwise)" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const section = try elf.findSection("perf_event");
    const bytes = try elf.readSectionData(section);
    const license = try elf.readSectionData(try elf.findSection("license"));

    var loader = Loader.init(testing.allocator, elf);
    defer loader.deinit();

    // The program's code with its map references left unpatched: the verifier must refuse it.
    const words = try testing.allocator.alloc(u64, bytes.len / 8);
    defer testing.allocator.free(words);
    const code = std.mem.sliceAsBytes(words);
    @memcpy(code, bytes);

    var log = std.mem.zeroes([64 * 1024]u8);

    if (Program.load(.perf_event, "onCpusample", code, license, &log)) |loaded| {
        var program = loaded;
        program.deinit();
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        error.VerifierRejected => {},
        else => return err,
    }
    try testing.expect(std.mem.sliceTo(&log, 0).len > 0);
}
