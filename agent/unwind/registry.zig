//! Every binary the agent has met, by identity, and what came of building its table: a module
//! in the table set, or why there is none. A binary is parsed once for the whole run, however
//! many times and in however many processes it is mapped.

const std = @import("std");
const assert = std.debug.assert;
const table = @import("table.zig");
const module_file = @import("module.zig");
const table_set = @import("table_set.zig");

/// What makes two mappings the same binary. A build ID when the file has one; otherwise its
/// inode and path, which is weaker (a file rewritten in place keeps both).
pub const Identity = union(enum) {
    build_id: []const u8,
    file: struct { inode: u64, path: []const u8 },
};

/// Why a binary has no table. A walk through such a binary falls back to frame pointers.
pub const Cause = enum {
    /// The file has no .eh_frame section.
    no_unwind_info,
    /// The .eh_frame section could not be read or converted.
    bad_unwind_info,
    /// One module has more rows than a bounded search can cover.
    table_too_large,
    /// The row array has no room left.
    table_full,
    /// The module array has no room left.
    too_many_modules,
    /// The registry has no room left to remember another binary.
    too_many_binaries,
    /// The file could not be opened or read, or it is not an ELF file.
    unreadable,
    /// The file at the mapped path is not the one the process mapped.
    wrong_file,
};

pub const Outcome = union(enum) {
    /// `delta` is the same for every mapping of the file: bias = start - offset - delta.
    loaded: struct { id: u32, delta: u64 },
    unavailable: Cause,
};

/// A build ID is at most 64 bytes in practice (find_build_id refuses more); a path is at most
/// PATH_MAX. The key is one kind byte, then the identity.
const key_size_max = 1 + 8 + 4096;

pub const Registry = struct {
    set: table_set.TableSet,
    /// Keys are owned. Failures are remembered too, so a file is not parsed again every window.
    known: std.StringHashMapUnmanaged(Outcome),
    binaries_max: u32,

    pub const Options = struct {
        rows_max: u32,
        modules_max: u32,
        /// Every binary remembered, with a table or without. Sized at init: the map never grows.
        binaries_max: u32,
    };

    pub fn init(registry: *Registry, gpa: std.mem.Allocator, options: Options) !void {
        assert(options.binaries_max >= options.modules_max);

        registry.* = .{ .set = undefined, .known = .empty, .binaries_max = options.binaries_max };
        try registry.known.ensureTotalCapacity(gpa, options.binaries_max);
        errdefer registry.known.deinit(gpa);
        try registry.set.init(gpa, .{
            .rows_max = options.rows_max,
            .modules_max = options.modules_max,
        });
    }

    pub fn deinit(registry: *Registry, gpa: std.mem.Allocator) void {
        var keys = registry.known.keyIterator();
        while (keys.next()) |key| gpa.free(key.*);
        registry.known.deinit(gpa);
        registry.set.deinit(gpa);
        registry.* = undefined;
    }

    /// The outcome remembered for `identity`, or null for a binary not met before. Allocates
    /// nothing: this runs for every mapping at every report.
    pub fn lookup(registry: *const Registry, identity: Identity) ?Outcome {
        var key_buffer: [key_size_max]u8 = undefined;
        const key = key_write(&key_buffer, identity) orelse return null;
        return registry.known.get(key);
    }

    /// Builds and stores the table of a binary not met before. On error nothing changes:
    /// everything that can fail runs before the set and the map change.
    pub fn add(
        registry: *Registry,
        gpa: std.mem.Allocator,
        identity: Identity,
        mapping: module_file.Mapping,
    ) error{OutOfMemory}!Outcome {
        assert(mapping.start < mapping.end);
        assert(registry.lookup(identity) == null);

        if (registry.known.count() == registry.binaries_max) {
            // Not remembered: there is no room. Every later report asks again and gets this.
            return .{ .unavailable = .too_many_binaries };
        }
        var key_buffer: [key_size_max]u8 = undefined;
        const key_borrowed = key_write(&key_buffer, identity) orelse
            return .{ .unavailable = .unreadable };
        const key = try gpa.dupe(u8, key_borrowed);
        errdefer gpa.free(key);

        const count_before = registry.known.count();
        const outcome = try registry.build(gpa, mapping);
        // Capacity was reserved at init, so this cannot fail: the set and the map agree.
        registry.known.putAssumeCapacityNoClobber(key, outcome);
        assert(registry.known.count() == count_before + 1);
        return outcome;
    }

    fn build(
        registry: *Registry,
        gpa: std.mem.Allocator,
        mapping: module_file.Mapping,
    ) error{OutOfMemory}!Outcome {
        var module: module_file.Module = undefined;
        module.load(gpa, mapping) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoUnwindInfo => return .{ .unavailable = .no_unwind_info },
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer module.deinit(gpa);

        var module_table: table.Table = undefined;
        module_table.init(gpa, module.fdes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer module_table.deinit(gpa);

        const module_id = registry.set.add(&module_table) catch |err| switch (err) {
            error.TableTooLarge => return .{ .unavailable = .table_too_large },
            error.TableFull => return .{ .unavailable = .table_full },
            error.TooManyModules => return .{ .unavailable = .too_many_modules },
        };
        assert(module_id < registry.set.modules_count);

        const delta = mapping.start -% mapping.offset -% module.bias;
        assert(bias_of(delta, mapping.start, mapping.offset) == module.bias);
        return .{ .loaded = .{ .id = module_id, .delta = delta } };
    }
};

/// The bias of a mapping of a file whose `delta` is known: runtime address = file address + bias.
pub fn bias_of(delta: u64, start: u64, offset: u64) u64 {
    return start -% offset -% delta;
}

/// Writes the key of `identity` into `buffer`. Keys never collide across kinds: the first byte
/// says which kind it is. Null for an identity too long to be a real one.
fn key_write(buffer: *[key_size_max]u8, identity: Identity) ?[]const u8 {
    switch (identity) {
        .build_id => |build_id| {
            assert(build_id.len > 0);
            if (build_id.len > key_size_max - 1) return null;
            buffer[0] = 'b';
            @memcpy(buffer[1..][0..build_id.len], build_id);
            return buffer[0 .. 1 + build_id.len];
        },
        .file => |file| {
            assert(file.path.len > 0);
            if (file.path.len > key_size_max - 9) return null;
            buffer[0] = 'f';
            std.mem.writeInt(u64, buffer[1..9], file.inode, .little);
            @memcpy(buffer[9..][0..file.path.len], file.path);
            return buffer[0 .. 9 + file.path.len];
        },
    }
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

const options_testing = Registry.Options{ .rows_max = 100, .modules_max = 4, .binaries_max = 4 };

test "a file that cannot be used is remembered, and not parsed again" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_testing);
    defer registry.deinit(testing.allocator);

    const identity = Identity{ .build_id = &.{ 1, 2, 3 } };
    try testing.expect(registry.lookup(identity) == null);

    const first = try registry.add(testing.allocator, identity, .{
        .file = "this is not an ELF file",
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
    });
    try testing.expect(first == .unavailable);

    const again = registry.lookup(identity) orelse return error.TestUnexpectedResult;
    try testing.expect(std.meta.eql(first, again));
    try testing.expectEqual(@as(u32, 0), registry.set.modules_count);
}

test "the two kinds of identity do not collide" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, options_testing);
    defer registry.deinit(testing.allocator);

    const mapping = module_file.Mapping{ .file = "", .start = 0, .end = 1, .offset = 0 };
    _ = try registry.add(testing.allocator, .{ .build_id = "abc" }, mapping);
    try testing.expect(registry.lookup(.{ .build_id = "abc" }) != null);
    try testing.expect(registry.lookup(.{ .file = .{ .inode = 1, .path = "abc" } }) == null);
    try testing.expect(registry.lookup(.{ .build_id = "abd" }) == null);
}

test "past binaries_max a binary is refused and not remembered" {
    var registry: Registry = undefined;
    try registry.init(testing.allocator, .{ .rows_max = 10, .modules_max = 1, .binaries_max = 2 });
    defer registry.deinit(testing.allocator);

    const mapping = module_file.Mapping{ .file = "", .start = 0, .end = 1, .offset = 0 };
    _ = try registry.add(testing.allocator, .{ .build_id = "a" }, mapping);
    _ = try registry.add(testing.allocator, .{ .build_id = "b" }, mapping);
    const third = try registry.add(testing.allocator, .{ .build_id = "c" }, mapping);
    try testing.expectEqual(Cause.too_many_binaries, third.unavailable);
    try testing.expect(registry.lookup(.{ .build_id = "c" }) == null);
    try testing.expectEqual(@as(u32, 2), registry.known.count());
}
