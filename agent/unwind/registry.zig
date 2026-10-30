const std = @import("std");
const assert = std.debug.assert;
const compact = @import("compact.zig");
const module = @import("module.zig");
const tableset = @import("tableset.zig");

pub const Identity = union(enum) {
    build_id: []const u8,
    file: struct {
        inode: u64,
        path: []const u8,
    },
};

/// Why a binary has no table. Every sample that needs such a binary is counted under it.
pub const Cause = enum {
    no_unwind_info,
    bad_unwind_info,
    scratch_full,
    table_too_large,
    table_full,
    too_many_modules,
    too_many_binaries,
    unreadable,
    wrong_file,
};

pub const Outcome = union(enum) {
    loaded: struct { id: u32, delta: u64 },
    unavailable: Cause,
};

pub const Registry = struct {
    set: tableset.TableSet,
    /// Owned keys. Failures are remembered too, so a file is not parsed again every window.
    known: std.StringHashMapUnmanaged(Outcome),

    pub fn init(
        registry: *Registry,
        gpa: std.mem.Allocator,
        options: tableset.TableSet.Options,
    ) !void {
        registry.* = .{ .set = undefined, .known = .empty };
        try registry.set.init(gpa, options);
    }

    pub fn deinit(registry: *Registry, gpa: std.mem.Allocator) void {
        var keys = registry.known.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        registry.known.deinit(gpa);
        registry.set.deinit(gpa);
        registry.* = undefined;
    }

    /// Builds and stores the table of a binary not seen before. A binary already known gives
    /// the stored outcome and its file is not read. On error nothing changes: everything that
    /// can fail runs before the set changes.
    pub fn add(
        registry: *Registry,
        gpa: std.mem.Allocator,
        identity: Identity,
        mapping: module.Mapping,
    ) !Outcome {
        assert(mapping.start <= mapping.end);

        const key = try key_of(gpa, identity);
        if (registry.known.get(key)) |existing| {
            gpa.free(key);
            return existing;
        }
        errdefer gpa.free(key);

        try registry.known.ensureUnusedCapacity(gpa, 1);
        const known_count = registry.known.count();
        const outcome = try registry.build(gpa, mapping);
        // Nothing below can fail, so the set and the map never disagree.
        registry.known.putAssumeCapacityNoClobber(key, outcome);

        assert(registry.known.count() == known_count + 1);
        return outcome;
    }

    pub fn lookup(
        registry: *const Registry,
        gpa: std.mem.Allocator,
        identity: Identity,
    ) !?Outcome {
        const key = try key_of(gpa, identity);
        defer gpa.free(key);
        return registry.known.get(key);
    }

    fn build(
        registry: *Registry,
        gpa: std.mem.Allocator,
        mapping: module.Mapping,
    ) error{OutOfMemory}!Outcome {
        var loaded: module.Module = undefined;
        loaded.load(gpa, mapping) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoUnwindInfo => return .{ .unavailable = .no_unwind_info },
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer loaded.deinit(gpa);

        var table: compact.Table = undefined;
        table.init(gpa, loaded.fdes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer table.deinit(gpa);

        const module_id = registry.set.add(&table) catch |err| switch (err) {
            error.TableTooLarge => return .{ .unavailable = .table_too_large },
            error.TableFull => return .{ .unavailable = .table_full },
            error.TooManyModules => return .{ .unavailable = .too_many_modules },
        };
        assert(module_id < registry.set.modules_count);

        return .{
            .loaded = .{
                .id = module_id,
                .delta = mapping.start -% mapping.offset -% loaded.bias,
            },
        };
    }
};

/// Keys never collide across kinds: the first byte says which kind it is.
fn key_of(gpa: std.mem.Allocator, identity: Identity) error{OutOfMemory}![]u8 {
    switch (identity) {
        .build_id => |build_id| {
            assert(build_id.len > 0);
            const key = try gpa.alloc(u8, 1 + build_id.len);
            key[0] = 'b';
            @memcpy(key[1..], build_id);
            return key;
        },
        .file => |file| {
            assert(file.path.len > 0);
            const key = try gpa.alloc(u8, 1 + 8 + file.path.len);
            key[0] = 'f';
            std.mem.writeInt(u64, key[1..9], file.inode, .little);
            @memcpy(key[9..], file.path);
            return key;
        },
    }
}

/// The bias of a mapping of a file whose `delta` is known: runtime address = file address + bias.
pub fn biasOf(delta: u64, start: u64, offset: u64) u64 {
    return start -% offset -% delta;
}

const testing = std.testing;

test "a file that cannot be used is remembered, and not parsed again" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, .{ .rows_max = 100, .modules_max = 4 });
    defer registry.deinit(testing.allocator);

    const identity = Identity{ .build_id = &.{ 1, 2, 3 } };
    try testing.expect((try registry.lookup(testing.allocator, identity)) == null);

    const first = try registry.add(testing.allocator, identity, .{
        .file = "this is not an ELF file",
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
    });
    try testing.expect(first == .unavailable);

    const again = (try registry.lookup(testing.allocator, identity)).?;
    try testing.expect(std.meta.eql(first, again));
    // A second add with the same identity answers from memory, whatever bytes it is given.
    const third = try registry.add(testing.allocator, identity, .{
        .file = "",
        .start = 0,
        .end = 0,
        .offset = 0,
    });
    try testing.expect(std.meta.eql(first, third));
    try testing.expectEqual(@as(u32, 0), registry.set.modules_count);
}

test "the two kinds of identity do not collide" {
    var r: Registry = undefined;
    try r.init(testing.allocator, .{ .rows_max = 100, .modules_max = 4 });
    defer r.deinit(testing.allocator);
    _ = try r.add(std.testing.allocator, .{ .build_id = "abc" }, .{ .file = "", .start = 0, .end = 0, .offset = 0 });
    try testing.expect((try r.lookup(testing.allocator, .{ .build_id = "abc" })) != null);
    try testing.expect((try r.lookup(testing.allocator, .{ .file = .{ .inode = 1, .path = "abc" } })) == null);
    try testing.expect((try r.lookup(testing.allocator, .{ .build_id = "abd" })) == null);
}
