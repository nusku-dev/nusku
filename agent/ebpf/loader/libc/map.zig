const std = @import("std");
const c = @import("clibs.zig").clibs;
const err = @import("error.zig");

const Error = err.Error;
const fromErrno = err.fromErrno;

pub const Map = struct {
    fd: c_int,
    key_size: u32,
    value_size: u32,

    pub const Spec = struct {
        map_type: u32,
        key_size: u32,
        value_size: u32,
        max_entries: u32,
    };

    /// Creates a map in the kernel. Needs root or CAP_BPF.
    pub fn create(name: [:0]const u8, spec: Spec) Error!Map {
        std.debug.assert(spec.key_size > 0 and spec.value_size > 0 and spec.max_entries > 0);
        const fd = c.bpf_map_create(spec.map_type, name.ptr, spec.key_size, spec.value_size, spec.max_entries, null);
        if (fd < 0) return fromErrno(-fd);
        return .{ .fd = fd, .key_size = spec.key_size, .value_size = spec.value_size };
    }

    pub fn deinit(self: *Map) void {
        _ = c.close(self.fd);
        self.* = undefined; // any later use trips over garbage in Debug
    }

    pub fn update(self: Map, key: []const u8, value: []const u8) Error!void {
        std.debug.assert(key.len == self.key_size and value.len == self.value_size);
        const rc = c.bpf_map_update_elem(self.fd, key.ptr, value.ptr, c.BPF_ANY);
        if (rc < 0) return fromErrno(-rc);
    }

    /// Returns false when the key is not in the map.
    pub fn lookup(self: Map, key: []const u8, value: []u8) Error!bool {
        std.debug.assert(key.len == self.key_size and value.len == self.value_size);
        const rc = c.bpf_map_lookup_elem(self.fd, key.ptr, value.ptr);
        if (rc == -c.ENOENT) return false;
        if (rc < 0) return fromErrno(-rc);
        return true;
    }

    /// Walks the keys: pass null for the first one, the previous key after that.
    /// Returns false after the last key.
    pub fn nextKey(self: Map, prev: ?[]const u8, next: []u8) Error!bool {
        std.debug.assert(next.len == self.key_size);
        if (prev) |p| std.debug.assert(p.len == self.key_size);
        const prev_ptr: ?*const anyopaque = if (prev) |p| p.ptr else null;
        const rc = c.bpf_map_get_next_key(self.fd, prev_ptr, next.ptr);
        if (rc == -c.ENOENT) return false;
        if (rc < 0) return fromErrno(-rc);
        return true;
    }
};

const testing = std.testing;

test "map update and lookup round-trip" {
    var map = Map.create("nusku_test", .{
        .map_type = c.BPF_MAP_TYPE_ARRAY,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 1,
    }) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };
    defer map.deinit();

    const key = std.mem.toBytes(@as(u32, 0));
    const expected = std.mem.toBytes(@as(u32, 4242));

    try map.update(&key, &expected);

    var actual: [4]u8 = undefined;
    try testing.expect(try map.lookup(&key, &actual));
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "map lookup returns false for a missing hash key" {
    var map = Map.create("nusku_test", .{
        .map_type = c.BPF_MAP_TYPE_HASH,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 4,
    }) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };
    defer map.deinit();

    const key = std.mem.toBytes(@as(u32, 123));
    var actual: [4]u8 = undefined;

    try testing.expect(!(try map.lookup(&key, &actual)));
}

test "map update replaces an existing value" {
    var map = Map.create("nusku_test", .{
        .map_type = c.BPF_MAP_TYPE_ARRAY,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 1,
    }) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };

    defer map.deinit();

    const key = std.mem.toBytes(@as(u32, 0));
    const first = std.mem.toBytes(@as(u32, 10));
    const second = std.mem.toBytes(@as(u32, 20));

    try map.update(&key, &first);
    try map.update(&key, &second);

    var actual: [4]u8 = undefined;
    try testing.expect(try map.lookup(&key, &actual));
    try testing.expectEqual(@as(u32, 20), std.mem.bytesToValue(u32, &actual));
}

test "map nextKey iterates array keys" {
    var map = Map.create("nusku_test", .{
        .map_type = c.BPF_MAP_TYPE_ARRAY,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 3,
    }) catch |erro| {
        if (erro == error.PermissionDenied or erro == error.NotSupported) {
            return error.SkipZigTest;
        }
        return erro;
    };
    defer map.deinit();

    var next: [4]u8 = undefined;

    // A null previous key requests the first key.
    try testing.expect(try map.nextKey(null, &next));
    try testing.expectEqual(@as(u32, 0), std.mem.bytesToValue(u32, &next));

    const previous = next;
    try testing.expect(try map.nextKey(&previous, &next));
    try testing.expectEqual(@as(u32, 1), std.mem.bytesToValue(u32, &next));

    const previous_second = next;
    try testing.expect(try map.nextKey(&previous_second, &next));
    try testing.expectEqual(@as(u32, 2), std.mem.bytesToValue(u32, &next));

    const previous_third = next;
    try testing.expect(!(try map.nextKey(&previous_third, &next)));
}
