//! The unwind tables in the kernel.

const std = @import("std");
const assert = std.debug.assert;
const unwind = @import("../unwind/unwind.zig");
const map_file = @import("bpf/map.zig");
const loader = @import("bpf/loader.zig");
const libbpf = @import("bpf/libbpf.zig");
const log = @import("../log.zig").agent;

const wire = unwind.wire;
const Map = map_file.Map;
const ProcessEntry = wire.ProcessEntry;
const Module = wire.Module;

pub const MapName = enum { unwind_rows, unwind_modules, unwind_procs };

pub const UnwindMaps = struct {
    maps: std.EnumArray(MapName, Map),
    modules_written: u32,
    entry_written: ProcessEntry,

    pub fn init(unwind_maps: *UnwindMaps) !void {
        unwind_maps.* = .{
            .maps = undefined,
            .modules_written = 0,
            .entry_written = std.mem.zeroes(ProcessEntry),
        };
        try maps_create(&unwind_maps.maps);
    }

    pub fn deinit(unwind_maps: *UnwindMaps) void {
        for (&unwind_maps.maps.values) |*map| map.deinit();
        unwind_maps.* = undefined;
    }

    pub fn bindings(unwind_maps: *const UnwindMaps) [3]loader.MapBinding {
        var result: [3]loader.MapBinding = undefined;
        for (&result, 0..) |*binding, index| {
            const name: MapName = @enumFromInt(index);
            binding.* = .{ .name = @tagName(name), .fd = unwind_maps.maps.get(name).fd };
        }
        return result;
    }

    pub fn write(unwind_maps: *UnwindMaps, pid: u32, tables: unwind.Tables) !void {
        assert(pid > 0);
        try unwind_maps.modules_write(tables);
        const entry_changed = !std.mem.eql(
            u8,
            std.mem.asBytes(tables.entry),
            std.mem.asBytes(&unwind_maps.entry_written),
        );
        if (entry_changed) try unwind_maps.process_write(pid, tables.entry);
    }

    fn modules_write(unwind_maps: *UnwindMaps, tables: unwind.Tables) !void {
        const count: u32 = @intCast(tables.modules.len);
        assert(unwind_maps.modules_written <= count);
        if (unwind_maps.modules_written == count) return;

        assert(tables.rows.len == wire.rows_max);
        const rows = unwind_maps.maps.getPtr(.unwind_rows);
        const key: u32 = 0;
        try rows.update(std.mem.asBytes(&key), std.mem.sliceAsBytes(tables.rows));

        const modules_map = unwind_maps.maps.getPtrConst(.unwind_modules);
        const modules = try map_file.TypedMap(u32, Module).init(modules_map);
        var module_id = unwind_maps.modules_written;
        while (module_id < count) : (module_id += 1) {
            try modules.update(module_id, &tables.modules[module_id]);
        }
        log.debug("unwind tables written to the kernel", .{
            .modules_first = unwind_maps.modules_written,
            .modules_count = count,
        });
        unwind_maps.modules_written = count;
    }

    fn process_write(unwind_maps: *UnwindMaps, pid: u32, entry: *const ProcessEntry) !void {
        for (entry.mappings[0..entry.count]) |mapping| {
            if (mapping.module != wire.module_none) {
                assert(mapping.module < unwind_maps.modules_written);
            }
        }
        const processes_map = unwind_maps.maps.getPtrConst(.unwind_procs);
        const processes = try map_file.TypedMap(u32, ProcessEntry).init(processes_map);
        try processes.update(pid, entry);
        unwind_maps.entry_written = entry.*;
    }
};

fn maps_create(maps: *std.EnumArray(MapName, Map)) libbpf.Error!void {
    const c = libbpf.c;
    const specs = std.EnumArray(MapName, map_file.Spec).init(.{
        .unwind_rows = .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = wire.rows_max * @sizeOf(wire.Row),
            .max_entries = 1,
        },
        .unwind_modules = .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(Module),
            .max_entries = wire.modules_max,
        },
        .unwind_procs = .{
            .map_type = c.BPF_MAP_TYPE_HASH,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(ProcessEntry),
            .max_entries = wire.processes_max,
        },
    });

    var created: u32 = 0;
    errdefer for (maps.values[0..created]) |*map| map.deinit();
    for (&maps.values, 0..) |*map, index| {
        const name: MapName = @enumFromInt(index);
        map.* = try Map.create(@tagName(name), specs.get(name));
        created += 1;
    }
}

const testing = std.testing;
const os = @import("../os/os.zig");
const target = @import("../target/target.zig");

test "write puts the tables in the kernel, and nothing when nothing changed (needs root)" {
    var unwind_maps: UnwindMaps = undefined;
    unwind_maps.init() catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    defer unwind_maps.deinit();

    const pid = os.process.current_pid();
    var own = try target.Target.init(testing.allocator, pid);
    defer own.deinit(testing.allocator);
    var tables: unwind.Unwind = undefined;
    try tables.init(testing.allocator, own.vdso_image());
    defer tables.deinit(testing.allocator);
    try tables.sync(testing.allocator, pid, own.regions);

    try unwind_maps.write(pid, tables.tables());
    try testing.expect(unwind_maps.modules_written > 0);
    try testing.expectEqual(tables.tables().modules.len, unwind_maps.modules_written);

    const processes_map = unwind_maps.maps.getPtrConst(.unwind_procs);
    const processes = try map_file.TypedMap(u32, ProcessEntry).init(processes_map);
    var entry_kernel: ProcessEntry = undefined;
    try testing.expect(try processes.lookup(pid, &entry_kernel));
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&unwind_maps.entry_written),
        std.mem.asBytes(&entry_kernel),
    );

    const modules_written = unwind_maps.modules_written;
    try tables.sync(testing.allocator, pid, own.regions);
    try unwind_maps.write(pid, tables.tables());
    try testing.expectEqual(modules_written, unwind_maps.modules_written);
}
