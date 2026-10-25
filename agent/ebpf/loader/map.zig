const std = @import("std");
const c = @import("../libc/import.zig").clibs;
const err = @import("../libc/error.zig");

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
        // A ring buffer has no keys or values: its size is `max_entries`, in bytes.
        const is_ring_buffer = spec.map_type == 27; // BPF_MAP_TYPE_RINGBUF
        std.debug.assert(spec.max_entries > 0);
        std.debug.assert(is_ring_buffer or (spec.key_size > 0 and spec.value_size > 0));
        if (is_ring_buffer) std.debug.assert(spec.key_size == 0 and spec.value_size == 0);

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

/// A map seen through its real key and value types.
pub fn TypedMap(comptime K: type, comptime V: type) type {
    comptime {
        assertPlainData(K);
        assertPlainData(V);
    }
    return struct {
        const Self = @This();
        raw: Map,

        /// Wraps `raw` after checking that its key and value sizes match K and V.
        /// This catches the kernel program and the Zig side drifting apart.
        pub fn init(raw: Map) Error!Self {
            if (raw.key_size != @sizeOf(K) or raw.value_size != @sizeOf(V)) return error.InvalidArgument;
            return .{ .raw = raw };
        }

        pub fn update(self: Self, key: K, value: V) Error!void {
            try self.raw.update(std.mem.asBytes(&key), std.mem.asBytes(&value));
        }

        /// Returns null when the key is not in the map.
        pub fn lookup(self: Self, key: K) Error!?V {
            var value: V = undefined;
            if (!try self.raw.lookup(std.mem.asBytes(&key), std.mem.asBytes(&value))) return null;
            return value;
        }

        /// Walks the keys: pass null for the first one, the previous key after that.
        /// Returns null after the last key.
        pub fn nextKey(self: Self, prev: ?K) Error!?K {
            var next: K = undefined;
            const found = if (prev) |p|
                try self.raw.nextKey(std.mem.asBytes(&p), std.mem.asBytes(&next))
            else
                try self.raw.nextKey(null, std.mem.asBytes(&next));
            return if (found) next else null;
        }
    };
}

/// Keys and values are copied byte for byte to and from the kernel, so their layout must be
/// fixed: integers, arrays, or extern structs. Padding bytes are rejected because they hold
/// garbage and the kernel compares keys by bytes.
fn assertPlainData(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => {},
        .array => |a| assertPlainData(a.child),
        .@"struct" => |s| {
            if (s.layout != .@"extern") @compileError(@typeName(T) ++ " must be an extern struct");
            var sum: usize = 0;
            inline for (s.fields) |f| {
                assertPlainData(f.type);
                sum += @sizeOf(f.type);
            }
            if (sum != @sizeOf(T)) @compileError(@typeName(T) ++ " has padding bytes");
        },
        else => @compileError("unsupported map type " ++ @typeName(T)),
    }
}

const testing = std.testing;

test "TypedMap checks the sizes of the map it wraps" {
    const Counters = TypedMap(u32, u64);
    _ = try Counters.init(.{ .fd = -1, .key_size = 4, .value_size = 8 });
    try std.testing.expectError(error.InvalidArgument, Counters.init(.{ .fd = -1, .key_size = 8, .value_size = 8 }));
    try std.testing.expectError(error.InvalidArgument, Counters.init(.{ .fd = -1, .key_size = 4, .value_size = 4 }));
}

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
