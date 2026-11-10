//! Loads a BPF object.

const std = @import("std");
const assert = std.debug.assert;
const libbpf = @import("libbpf.zig");
const object_file = @import("object.zig");
const map_file = @import("map.zig");
const program_file = @import("program.zig");

const Map = map_file.Map;
const Object = object_file.Object;
const Program = program_file.Program;

pub const Error = libbpf.Error || object_file.Error || error{ UnknownMap, MapMismatch };

const log = @import("../../log.zig").agent;

const relocation_map: u32 = 1;
const opcode_load_immediate_64: u8 = 0x18;
const pseudo_map_fd: u8 = 1;

pub const MapBinding = struct {
    name: []const u8,
    fd: i32,
};

pub fn map_create(object: *const Object, name: [:0]const u8) Error!Map {
    const definition = try object.map_definition(name);
    return Map.create(name, .{
        .map_type = definition.map_type,
        .key_size = definition.key_size,
        .value_size = definition.value_size,
        .max_entries = definition.max_entries,
    });
}

pub fn map_check(object: *const Object, name: []const u8, map: *const Map) Error!void {
    const definition = try object.map_definition(name);
    if (definition.map_type != map.spec.map_type) return error.MapMismatch;
    if (definition.key_size != map.spec.key_size) return error.MapMismatch;
    if (definition.value_size != map.spec.value_size) return error.MapMismatch;
    if (definition.max_entries != map.spec.max_entries) return error.MapMismatch;
}

pub const LoadOptions = struct {
    kind: Program.Kind,
    section: []const u8,
    function: [:0]const u8,
    maps: []const MapBinding,
};

/// `gpa` holds a copy of the code and the verifier's log during the call.
pub fn program_load(gpa: std.mem.Allocator, object: *const Object, options: LoadOptions) !Program {
    assert(options.maps.len > 0);

    const section = try object.section_find(options.section);
    const function = try object.symbol_find(options.function);
    const section_bytes = try object.section_bytes(section);
    if (function.section != section.index) return error.Unsupported;
    if (function.value != 0) return error.Unsupported;
    if (function.size != section_bytes.len) return error.Unsupported;
    if (section_bytes.len == 0) return error.Unsupported;
    if (section_bytes.len % program_file.instruction_size != 0) return error.Unsupported;

    const words = try gpa.alloc(u64, section_bytes.len / program_file.instruction_size);
    defer gpa.free(words);
    const code = std.mem.sliceAsBytes(words);
    @memcpy(code, section_bytes);

    try relocations_apply(object, section, code, options.maps);

    const license = try object.section_bytes(try object.section_find("license"));
    // The verifier's explanation of a refused program is long: 64 KiB holds the usual ones.
    const verifier_log = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(verifier_log);

    const program = Program.load(.{
        .kind = options.kind,
        .name = options.function,
        .instructions = code,
        .license = license,
        .log = verifier_log,
    }) catch |err| {
        if (err == error.VerifierRejected) {
            log.err("the kernel's verifier refused the BPF program", .{
                .program = options.function,
                .verifier_log = std.mem.sliceTo(verifier_log, 0),
            });
        }
        return err;
    };
    log.debug("bpf program loaded", .{
        .program = options.function,
        .instructions = code.len / program_file.instruction_size,
        .maps = options.maps.len,
    });
    return program;
}

pub fn relocations_apply(
    object: *const Object,
    program: object_file.Section,
    code: []u8,
    maps: []const MapBinding,
) Error!void {
    const maps_section = try object.section_find(".maps");

    var relocations = try object.relocations(program);
    while (try relocations.next()) |relocation| {
        if (relocation.target.section != maps_section.index) return error.Unsupported;
        if (relocation.kind != relocation_map) return error.Unsupported;
        if (relocation.offset + 16 > code.len) return error.Unsupported;
        const at: usize = @intCast(relocation.offset);
        if (code[at] != opcode_load_immediate_64) return error.Unsupported;

        const immediate = code[at + 4 ..][0..4];
        const definition_offset = std.mem.readInt(i32, immediate, .little);
        const fd = try map_fd_find(object, maps, definition_offset);

        code[at + 1] = (code[at + 1] & 0x0f) | (pseudo_map_fd << 4);
        std.mem.writeInt(i32, immediate, fd, .little);
    }
}

fn map_fd_find(object: *const Object, maps: []const MapBinding, definition_offset: i32) Error!i32 {
    if (definition_offset < 0) return error.Unsupported;
    for (maps) |binding| {
        const symbol = try object.symbol_find(binding.name);
        if (symbol.value == @as(u64, @intCast(definition_offset))) {
            assert(binding.fd >= 0);
            return binding.fd;
        }
    }
    return error.UnknownMap;
}

const testing = std.testing;

test "creates three maps of three kinds from their definitions (needs root, skipped otherwise)" {
    const object = try Object.init(@embedFile("loader_testing_bpf"));

    var stacks = map_create(&object, "stacks") catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    defer stacks.deinit();
    var counts = try map_create(&object, "counts");
    defer counts.deinit();
    var target_pid = try map_create(&object, "target_pid");
    defer target_pid.deinit();

    try map_check(&object, "target_pid", &target_pid);
    try testing.expectError(error.MapMismatch, map_check(&object, "stacks", &counts));

    const typed = try map_file.TypedMap(u32, u32).init(&target_pid);
    try typed.update(0, &@as(u32, 4242));
    var value: u32 = 0;
    try testing.expect(try typed.lookup(0, &value));
    try testing.expectEqual(@as(u32, 4242), value);
}

test "relocations_apply fills in the descriptors and touches nothing else" {
    const object = try Object.init(@embedFile("loader_testing_bpf"));
    const program = try object.section_find("perf_event");
    const original = try object.section_bytes(program);

    const code = try testing.allocator.dupe(u8, original);
    defer testing.allocator.free(code);

    const maps = [_]MapBinding{
        .{ .name = "stacks", .fd = 100 },
        .{ .name = "counts", .fd = 101 },
        .{ .name = "target_pid", .fd = 102 },
    };
    try relocations_apply(&object, program, code, &maps);

    var patched_at: [32]u64 = undefined;
    var patched_count: u32 = 0;
    var relocations = try object.relocations(program);
    while (try relocations.next()) |relocation| {
        patched_at[patched_count] = relocation.offset;
        patched_count += 1;

        const at: usize = @intCast(relocation.offset);
        const before = std.mem.readInt(i32, original[at + 4 ..][0..4], .little);
        const expected: i32 = for (maps) |binding| {
            if ((try object.symbol_find(binding.name)).value == before) break binding.fd;
        } else return error.TestUnexpectedResult;

        try testing.expectEqual(pseudo_map_fd, code[at + 1] >> 4);
        try testing.expectEqual(original[at + 1] & 0x0f, code[at + 1] & 0x0f);
        try testing.expectEqual(expected, std.mem.readInt(i32, code[at + 4 ..][0..4], .little));
    }
    try testing.expect(patched_count >= 3);

    for (code, original, 0..) |got, want, byte| {
        var patchable = false;
        for (patched_at[0..patched_count]) |offset| {
            if (byte == offset + 1) patchable = true;
            if (byte >= offset + 4 and byte < offset + 8) patchable = true;
        }
        if (!patchable) try testing.expectEqual(want, got);
    }
}

test "relocations_apply fails when a map the code uses is not bound" {
    const object = try Object.init(@embedFile("loader_testing_bpf"));
    const program = try object.section_find("perf_event");

    const code = try testing.allocator.dupe(u8, try object.section_bytes(program));
    defer testing.allocator.free(code);

    const maps = [_]MapBinding{
        .{ .name = "stacks", .fd = 101 },
        .{ .name = "target_pid", .fd = 102 },
    };
    try testing.expectError(error.UnknownMap, relocations_apply(&object, program, code, &maps));
}

test "every relocation of the cpu program refers to a map the collector binds" {
    const cpu_maps = [_][]const u8{
        "cpu_config",  "cpu_state",   "cpu_walk_next",  "cpu_counts",
        "cpu_records", "unwind_rows", "unwind_modules", "unwind_procs",
    };
    const object = try Object.init(@embedFile("cpu_bpf"));
    const program = try object.section_find("perf_event/cpu_sample");
    const maps_section = try object.section_find(".maps");
    try testing.expectEqual(@as(u64, cpu_maps.len * 16), maps_section.size);

    var bindings: [cpu_maps.len]MapBinding = undefined;
    for (&bindings, cpu_maps, 0..) |*binding, name, index| {
        binding.* = .{ .name = name, .fd = @intCast(100 + index) };
    }
    const code = try testing.allocator.dupe(u8, try object.section_bytes(program));
    defer testing.allocator.free(code);
    try relocations_apply(&object, program, code, &bindings);

    var seen: [cpu_maps.len]bool = @splat(false);
    var relocations = try object.relocations(program);
    while (try relocations.next()) |relocation| {
        const fd = std.mem.readInt(i32, code[@intCast(relocation.offset + 4)..][0..4], .little);
        seen[@intCast(fd - 100)] = true;
    }
    for (seen) |used| try testing.expect(used);
}
