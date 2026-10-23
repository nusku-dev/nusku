//! The unwind tables as BPF maps. All rows are one value of a one-entry array, so the BPF
//! program takes a single pointer and indexes it; module descriptors and per-process mapping
//! lists are separate maps. Layout comes from `unwind.tableset` and `unwind.procmap`.
const std = @import("std");
const unwind = @import("unwind");
const c = @import("../libc/import.zig").clibs;
const map = @import("map.zig");

const Row = unwind.compact.Row;
const Module = unwind.tableset.Module;
const TableSet = unwind.tableset.TableSet;
const ProcessEntry = unwind.procmap.ProcessEntry;

pub const Limits = struct {
    max_rows: u32,
    max_modules: u32,
    /// Each process costs `@sizeOf(ProcessEntry)` (about 4 KB) of kernel memory up front.
    max_processes: u32 = 1024,
};

pub const TableMaps = struct {
    allocator: std.mem.Allocator,
    /// One entry, key 0, holding every row.
    rows: map.Map,
    /// What `rows` holds. New rows are added here and the whole value is written again.
    image: []Row,
    modules: map.TypedMap(u32, Module),
    processes: map.TypedMap(u32, ProcessEntry),
    owns_maps: bool,

    pub fn create(allocator: std.mem.Allocator, limits: Limits) !TableMaps {
        var rows_raw = try map.Map.create("nusku_rows", .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = limits.max_rows * @sizeOf(Row),
            .max_entries = 1,
        });
        errdefer rows_raw.deinit();
        var modules_raw = try map.Map.create("nusku_modules", .{
            .map_type = c.BPF_MAP_TYPE_ARRAY,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(Module),
            .max_entries = limits.max_modules,
        });
        errdefer modules_raw.deinit();
        var processes_raw = try map.Map.create("nusku_procs", .{
            .map_type = c.BPF_MAP_TYPE_HASH,
            .key_size = @sizeOf(u32),
            .value_size = @sizeOf(ProcessEntry),
            .max_entries = limits.max_processes,
        });
        errdefer processes_raw.deinit();

        const image = try allocator.alloc(Row, limits.max_rows);
        errdefer allocator.free(image);
        @memset(image, std.mem.zeroes(Row));
        return .{
            .allocator = allocator,
            .rows = rows_raw,
            .image = image,
            .modules = try map.TypedMap(u32, Module).init(modules_raw),
            .processes = try map.TypedMap(u32, ProcessEntry).init(processes_raw),
            .owns_maps = true,
        };
    }

    /// Wraps maps created from the BPF object, which fixes their sizes. The sizes of keys and
    /// values are checked. The result does not own the maps; `deinit` only frees the image.
    pub fn wrap(allocator: std.mem.Allocator, rows: map.Map, modules: map.Map, processes: map.Map) !TableMaps {
        if (rows.key_size != @sizeOf(u32) or rows.value_size == 0 or rows.value_size % @sizeOf(Row) != 0) {
            return error.InvalidArgument;
        }
        const image = try allocator.alloc(Row, rows.value_size / @sizeOf(Row));
        errdefer allocator.free(image);
        @memset(image, std.mem.zeroes(Row));
        return .{
            .allocator = allocator,
            .rows = rows,
            .image = image,
            .modules = try map.TypedMap(u32, Module).init(modules),
            .processes = try map.TypedMap(u32, ProcessEntry).init(processes),
            .owns_maps = false,
        };
    }

    pub fn deinit(self: *TableMaps) void {
        self.allocator.free(self.image);
        if (self.owns_maps) {
            self.rows.deinit();
            self.modules.raw.deinit();
            self.processes.raw.deinit();
        }
        self.* = undefined;
    }

    /// Writes modules `from` and later, the ones the kernel does not have yet: first the rows
    /// (the whole image, whose earlier rows have not changed), then the descriptors, so a
    /// descriptor never points at rows that are not there yet.
    pub fn writeModulesFrom(self: *TableMaps, set: TableSet, from: usize) !void {
        if (from >= set.modules.items.len) return;
        const first: usize = set.modules.items[from].row_start;
        const end = set.rows.items.len;
        if (end > self.image.len) return error.TableFull;
        @memcpy(self.image[first..end], set.rows.items[first..end]);

        const key = std.mem.toBytes(@as(u32, 0));
        try self.rows.update(&key, std.mem.sliceAsBytes(self.image));
        for (from..set.modules.items.len) |id| try self.modules.update(@intCast(id), set.modules.items[id]);
    }

    /// Call after the modules the entry names have been written.
    pub fn writeProcess(self: TableMaps, pid: u32, entry: ProcessEntry) !void {
        try self.processes.update(pid, entry);
    }

    /// Returns false when the process was not in the map.
    pub fn removeProcess(self: TableMaps, pid: u32) !bool {
        return self.processes.delete(pid);
    }

    pub fn readProcess(self: TableMaps, pid: u32) !?ProcessEntry {
        return self.processes.lookup(pid);
    }

    pub fn readModule(self: TableMaps, id: u32) !Module {
        return (try self.modules.lookup(id)) orelse error.NotFound;
    }

    /// Every row as the kernel holds it. The caller frees the result with `allocator`.
    pub fn readRows(self: TableMaps) ![]Row {
        const out = try self.allocator.alloc(Row, self.image.len);
        errdefer self.allocator.free(out);
        const key = std.mem.toBytes(@as(u32, 0));
        if (!try self.rows.lookup(&key, std.mem.sliceAsBytes(out))) return error.NotFound;
        return out;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn skipWithoutPrivilege(err: anyerror) anyerror {
    if (err == error.PermissionDenied or err == error.NotSupported) return error.SkipZigTest;
    return err;
}

fn testRow(i: u32) Row {
    return .{
        .pc = i * 4,
        .cfa_offset = @as(i32, @intCast(i % 200)) - 50,
        .cfa_type = @intCast(2 + i % 4),
        .rbp_type = @intCast(i % 2),
        .rbp_offset = -@as(i16, @intCast(i % 100)),
    };
}

/// Everything the set holds is in the kernel, byte for byte, and the rest of the rows are zeros.
fn expectSetInKernel(maps: TableMaps, set: TableSet) !void {
    const kernel_rows = try maps.readRows();
    defer maps.allocator.free(kernel_rows);
    const n = set.rows.items.len;
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(set.rows.items), std.mem.sliceAsBytes(kernel_rows[0..n]));
    for (kernel_rows[n..]) |r| try testing.expectEqual(@as(u8, 0), r.cfa_type);

    for (set.modules.items, 0..) |want, id| {
        const got = try maps.readModule(@intCast(id));
        try testing.expectEqualSlices(u8, std.mem.asBytes(&want), std.mem.asBytes(&got));
    }
}

test "rows and descriptors written to the kernel come back unchanged" {
    var maps = TableMaps.create(testing.allocator, .{ .max_rows = 5000, .max_modules = 4 }) catch |e| return skipWithoutPrivilege(e);
    defer maps.deinit();

    var rows: [1200]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = testRow(@intCast(i));
    var set = TableSet.init(testing.allocator, 5000, 4);
    defer set.deinit();
    _ = try set.add(.{ .base = 0x1000, .end = 4800, .rows = &rows });
    _ = try set.add(.{ .base = 0x9000_0000, .end = 4000, .rows = rows[0..700] });
    try maps.writeModulesFrom(set, 0);
    try expectSetInKernel(maps, set);
    std.debug.print("tablemaps: {d} rows in {d} modules read back from the kernel, all equal\n", .{ set.rows.items.len, set.modules.items.len });
}

test "modules added later are written without changing the earlier ones" {
    var maps = TableMaps.create(testing.allocator, .{ .max_rows = 100, .max_modules = 4, .max_processes = 4 }) catch |e| return skipWithoutPrivilege(e);
    defer maps.deinit();

    var rows: [30]Row = undefined;
    for (&rows, 0..) |*r, i| r.* = testRow(@intCast(i));
    var set = TableSet.init(testing.allocator, 100, 4);
    defer set.deinit();
    _ = try set.add(.{ .base = 0x1000, .end = 120, .rows = rows[0..10] });
    _ = try set.add(.{ .base = 0x2000, .end = 80, .rows = rows[10..30] });
    try maps.writeModulesFrom(set, 0);
    try expectSetInKernel(maps, set);

    const known = set.modules.items.len;
    _ = try set.add(.{ .base = 0x3000, .end = 40, .rows = rows[0..5] });
    try maps.writeModulesFrom(set, known);
    try expectSetInKernel(maps, set);
}

fn entryWith(module: u32) !ProcessEntry {
    const inputs = [_]unwind.procmap.Input{
        .{ .start = 0x400000, .end = 0x401000, .offset = 0, .outcome = .{ .loaded = .{ .id = module, .delta = 0 } } },
        .{ .start = 0x7f00_0000_0000, .end = 0x7f00_0000_1000, .offset = 0, .outcome = .{ .unavailable = .unreadable } },
    };
    return unwind.procmap.build(&inputs);
}

test "process entries: write, read back, replace, remove" {
    var maps = TableMaps.create(testing.allocator, .{ .max_rows = 10, .max_modules = 2, .max_processes = 4 }) catch |e| return skipWithoutPrivilege(e);
    defer maps.deinit();

    const one = try entryWith(1);
    const two = try entryWith(2);
    try testing.expect((try maps.readProcess(100)) == null);

    try maps.writeProcess(100, one);
    try maps.writeProcess(200, two);
    const got_one = (try maps.readProcess(100)).?;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&one), std.mem.asBytes(&got_one));

    const five = try entryWith(5);
    try maps.writeProcess(100, five); // the process loaded a library: its entry is replaced
    const got_five = (try maps.readProcess(100)).?;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&five), std.mem.asBytes(&got_five));

    try testing.expect(try maps.removeProcess(100));
    try testing.expect(!(try maps.removeProcess(100)));
    try testing.expect((try maps.readProcess(100)) == null);
    const got_two = (try maps.readProcess(200)).?;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&two), std.mem.asBytes(&got_two));
}

test "a full process map refuses a new process, keeps the old ones, and takes it after a removal" {
    var maps = TableMaps.create(testing.allocator, .{ .max_rows = 10, .max_modules = 2, .max_processes = 2 }) catch |e| return skipWithoutPrivilege(e);
    defer maps.deinit();

    const entry = try entryWith(1);
    try maps.writeProcess(1, entry);
    try maps.writeProcess(2, entry);
    if (maps.writeProcess(3, entry)) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect((try maps.readProcess(1)) != null);
    try testing.expect((try maps.readProcess(2)) != null);
    try testing.expect((try maps.readProcess(3)) == null);

    try testing.expect(try maps.removeProcess(1));
    try maps.writeProcess(3, entry);
    std.debug.print("tablemaps: process entries of {d} bytes written, replaced, removed and refused when full\n", .{@sizeOf(ProcessEntry)});
}
