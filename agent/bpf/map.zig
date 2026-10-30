//! A BPF map seen from the agent: create, update, look up, and the batch operations that read or
//! delete many entries in one system call.

const std = @import("std");
const assert = std.debug.assert;
const libbpf = @import("libbpf.zig");

const c = libbpf.c;
const Error = libbpf.Error;
const error_from_errno = libbpf.error_from_errno;

pub const Spec = struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,

    pub fn is_ring_buffer(spec: Spec) bool {
        return spec.map_type == c.BPF_MAP_TYPE_RINGBUF;
    }
};

pub const Map = struct {
    fd: i32,
    spec: Spec,

    /// Creates a map in the kernel. Needs root or CAP_BPF. The kernel keeps only the first 15
    /// bytes of `name`.
    pub fn create(name: [:0]const u8, spec: Spec) Error!Map {
        assert(name.len > 0);
        assert(spec.max_entries > 0);
        if (spec.is_ring_buffer()) {
            // A ring buffer has no keys or values: `max_entries` is its size in bytes.
            assert(spec.key_size == 0);
            assert(spec.value_size == 0);
        } else {
            assert(spec.key_size > 0);
            assert(spec.value_size > 0);
        }

        const fd = c.bpf_map_create(
            spec.map_type,
            name.ptr,
            spec.key_size,
            spec.value_size,
            spec.max_entries,
            null,
        );
        if (fd < 0) return error_from_errno(-fd);
        assert(fd >= 0);
        return .{ .fd = fd, .spec = spec };
    }

    pub fn deinit(map: *Map) void {
        assert(map.fd >= 0);
        _ = std.os.linux.close(map.fd);
        map.* = undefined; // A use after this trips over garbage in Debug builds.
    }

    /// For a per-CPU map, `value` holds one value for each possible CPU.
    pub fn update(map: *const Map, key: []const u8, value: []const u8) Error!void {
        assert(key.len == map.spec.key_size);
        assert(value.len >= map.spec.value_size);

        const result = c.bpf_map_update_elem(map.fd, key.ptr, value.ptr, c.BPF_ANY);
        if (result < 0) return error_from_errno(-result);
    }

    /// Returns false when the key is not in the map. For a per-CPU map, `value` receives one
    /// value for each possible CPU.
    pub fn lookup(map: *const Map, key: []const u8, value: []u8) Error!bool {
        assert(key.len == map.spec.key_size);
        assert(value.len >= map.spec.value_size);

        const result = c.bpf_map_lookup_elem(map.fd, key.ptr, value.ptr);
        if (result == -c.ENOENT) return false;
        if (result < 0) return error_from_errno(-result);
        return true;
    }

    /// Copies every entry into `keys` and `values`, and returns how many there are. The buffers
    /// hold `max_entries` entries, so one call is usually enough. The map is not changed.
    ///
    /// The kernel walks a hash map bucket by bucket, so entries inserted during the call may or
    /// may not be in the result. No entry is returned twice.
    pub fn lookup_batch(map: *const Map, keys: []u8, values: []u8) Error!u32 {
        assert(keys.len == @as(u64, map.spec.key_size) * map.spec.max_entries);
        assert(values.len == @as(u64, map.spec.value_size) * map.spec.max_entries);

        var count_total: u32 = 0;
        var token_in: u32 = 0;
        var token_out: u32 = 0;
        var first = true;
        // Every call that does not end the walk returns at least one entry.
        var calls: u32 = 0;
        while (calls <= map.spec.max_entries) : (calls += 1) {
            const capacity = map.spec.max_entries - count_total;
            if (capacity == 0) return count_total;

            var count: u32 = capacity;
            const result = c.bpf_map_lookup_batch(
                map.fd,
                if (first) null else &token_in,
                &token_out,
                keys[@as(u64, count_total) * map.spec.key_size ..].ptr,
                values[@as(u64, count_total) * map.spec.value_size ..].ptr,
                &count,
                null,
            );
            assert(count <= capacity);
            count_total += count;
            // ENOENT ends the walk, and still comes with the entries of its last batch.
            if (result == -c.ENOENT) return count_total;
            if (result < 0) return error_from_errno(-result);

            first = false;
            token_in = token_out;
        }
        unreachable; // More calls than entries: the kernel kept returning empty batches.
    }

    /// Deletes the entries whose keys are in `keys`, `count` keys of `key_size` bytes.
    pub fn delete_batch(map: *const Map, keys: []const u8, count: u32) Error!void {
        assert(count <= map.spec.max_entries);
        assert(keys.len >= @as(u64, count) * map.spec.key_size);
        if (count == 0) return;

        var deleted: u32 = count;
        const result = c.bpf_map_delete_batch(map.fd, keys.ptr, &deleted, null);
        if (result < 0) return error_from_errno(-result);
        assert(deleted == count);
    }
};

/// A map seen through its key and value types.
pub fn TypedMap(comptime Key: type, comptime Value: type) type {
    comptime {
        plain_data_assert(Key);
        plain_data_assert(Value);
    }
    return struct {
        map: *const Map,

        const Self = @This();

        /// Checks that the map's key and value sizes are those of Key and Value, which catches
        /// the kernel program and the agent drifting apart.
        pub fn init(map: *const Map) Error!Self {
            if (map.spec.key_size != @sizeOf(Key)) return error.InvalidArgument;
            if (map.spec.value_size != @sizeOf(Value)) return error.InvalidArgument;
            return .{ .map = map };
        }

        pub fn update(typed: Self, key: Key, value: *const Value) Error!void {
            try typed.map.update(std.mem.asBytes(&key), std.mem.asBytes(value));
        }

        /// Returns false when the key is not in the map.
        pub fn lookup(typed: Self, key: Key, value: *Value) Error!bool {
            return typed.map.lookup(std.mem.asBytes(&key), std.mem.asBytes(value));
        }

        pub fn lookup_batch(typed: Self, keys: []Key, values: []Value) Error!u32 {
            return typed.map.lookup_batch(std.mem.sliceAsBytes(keys), std.mem.sliceAsBytes(values));
        }

        pub fn delete_batch(typed: Self, keys: []const Key) Error!void {
            assert(keys.len <= typed.map.spec.max_entries);
            try typed.map.delete_batch(std.mem.sliceAsBytes(keys), @intCast(keys.len));
        }
    };
}

/// Keys and values are copied byte for byte to and from the kernel, so their layout must be
/// fixed: integers, arrays, or extern structs. Padding is refused: it holds garbage, and the
/// kernel compares keys byte by byte.
fn plain_data_assert(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => {},
        .array => |array| plain_data_assert(array.child),
        .@"struct" => |structure| {
            if (structure.layout != .@"extern") {
                @compileError(@typeName(T) ++ " must be an extern struct");
            }
            var size_sum: u64 = 0;
            for (structure.fields) |field| {
                plain_data_assert(field.type);
                size_sum += @sizeOf(field.type);
            }
            if (size_sum != @sizeOf(T)) @compileError(@typeName(T) ++ " has padding bytes");
        },
        else => @compileError("a map cannot hold " ++ @typeName(T)),
    }
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// Creates a map, or skips the test without the rights to.
fn map_create_testing(spec: Spec) !Map {
    return Map.create("nusku_test", spec) catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
}

test "TypedMap checks the sizes of the map it wraps" {
    const Counters = TypedMap(u32, u64);
    const spec = Spec{
        .map_type = c.BPF_MAP_TYPE_HASH,
        .key_size = 4,
        .value_size = 8,
        .max_entries = 1,
    };
    _ = try Counters.init(&.{ .fd = -1, .spec = spec });

    var wrong_key = spec;
    wrong_key.key_size = 8;
    const map_wrong_key = Map{ .fd = -1, .spec = wrong_key };
    try testing.expectError(error.InvalidArgument, Counters.init(&map_wrong_key));
    var wrong_value = spec;
    wrong_value.value_size = 4;
    const map_wrong_value = Map{ .fd = -1, .spec = wrong_value };
    try testing.expectError(error.InvalidArgument, Counters.init(&map_wrong_value));
}

test "update, lookup and replace (needs root, skipped otherwise)" {
    var map = try map_create_testing(.{
        .map_type = c.BPF_MAP_TYPE_ARRAY,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 1,
    });
    defer map.deinit();

    const typed = try TypedMap(u32, u32).init(&map);
    try typed.update(0, &@as(u32, 10));
    try typed.update(0, &@as(u32, 20));

    var value: u32 = 0;
    try testing.expect(try typed.lookup(0, &value));
    try testing.expectEqual(@as(u32, 20), value);
}

test "lookup of a missing hash key is false (needs root, skipped otherwise)" {
    var map = try map_create_testing(.{
        .map_type = c.BPF_MAP_TYPE_HASH,
        .key_size = 4,
        .value_size = 4,
        .max_entries = 4,
    });
    defer map.deinit();

    var value: u32 = 0;
    try testing.expect(!(try (try TypedMap(u32, u32).init(&map)).lookup(123, &value)));
}

test "lookup_batch reads every entry and delete_batch removes the chosen ones (needs root)" {
    const entries_max = 64;
    var map = try map_create_testing(.{
        .map_type = c.BPF_MAP_TYPE_HASH,
        .key_size = 4,
        .value_size = 8,
        .max_entries = entries_max,
    });
    defer map.deinit();
    const typed = try TypedMap(u32, u64).init(&map);

    var key: u32 = 0;
    while (key < 40) : (key += 1) try typed.update(key, &(@as(u64, key) * 10));

    var keys: [entries_max]u32 = undefined;
    var values: [entries_max]u64 = undefined;
    const count = try typed.lookup_batch(&keys, &values);
    try testing.expectEqual(@as(u32, 40), count);
    for (keys[0..count], values[0..count]) |k, v| try testing.expectEqual(@as(u64, k) * 10, v);

    // Delete the even keys only.
    var even: [entries_max]u32 = undefined;
    var even_count: u32 = 0;
    for (keys[0..count]) |k| {
        if (k % 2 == 0) {
            even[even_count] = k;
            even_count += 1;
        }
    }
    try typed.delete_batch(even[0..even_count]);
    try testing.expectEqual(@as(u32, 20), try typed.lookup_batch(&keys, &values));
    for (keys[0..20]) |k| try testing.expect(k % 2 == 1);

    // An empty map reads as zero entries.
    try typed.delete_batch(keys[0..20]);
    try testing.expectEqual(@as(u32, 0), try typed.lookup_batch(&keys, &values));
}
