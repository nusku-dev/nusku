//! Which binaries have their unwind tables loaded. A binary is known by its build ID, or by
//! inode and path when it has none, so every process that maps libc shares one module. What
//! is stored per binary is not a bias (that differs per process) but a `delta`, from which the
//! bias of any mapping of the same file follows.
const std = @import("std");
const compact = @import("compact.zig");
const module = @import("module.zig");
const tableset = @import("tableset.zig");

pub const Identity = union(enum) {
    build_id: []const u8,
    file: struct { inode: u64, path: []const u8 },
};

/// Why a binary has no table. Every sample that needs such a binary is counted under it.
pub const Cause = enum { no_unwind_info, bad_unwind_info, table_full, too_many_modules, unreadable, wrong_file };

pub const Outcome = union(enum) {
    loaded: struct { id: u32, delta: u64 },
    unavailable: Cause,
};

/// The bias of a mapping of a file whose `delta` is known: runtime address = file address + bias.
pub fn biasOf(delta: u64, start: u64, offset: u64) u64 {
    return start -% offset -% delta;
}

/// Keys never collide across kinds: the first byte says which kind it is.
fn keyOf(allocator: std.mem.Allocator, identity: Identity) std.mem.Allocator.Error![]u8 {
    switch (identity) {
        .build_id => |id| {
            const key = try allocator.alloc(u8, 1 + id.len);
            key[0] = 'b';
            @memcpy(key[1..], id);
            return key;
        },
        .file => |f| {
            const key = try allocator.alloc(u8, 1 + 8 + f.path.len);
            key[0] = 'f';
            std.mem.writeInt(u64, key[1..9], f.inode, .little);
            @memcpy(key[9..], f.path);
            return key;
        },
    }
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    set: tableset.TableSet,
    /// Owned keys. Failures are remembered too, so a file is not parsed again every window.
    known: std.StringHashMapUnmanaged(Outcome) = .empty,

    pub fn init(allocator: std.mem.Allocator, max_rows: u32, max_modules: u32) Registry {
        return .{ .allocator = allocator, .set = tableset.TableSet.init(allocator, max_rows, max_modules) };
    }

    pub fn deinit(self: *Registry) void {
        var keys = self.known.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.known.deinit(self.allocator);
        self.set.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *Registry, identity: Identity) std.mem.Allocator.Error!?Outcome {
        const key = try keyOf(self.allocator, identity);
        defer self.allocator.free(key);
        return self.known.get(key);
    }

    /// Builds and stores the table of a binary not seen before, from the bytes of its file and
    /// one mapping of it. A binary already known gives the stored outcome and `file` is not read.
    pub fn add(
        self: *Registry,
        identity: Identity,
        file: []const u8,
        start: u64,
        end: u64,
        offset: u64,
    ) std.mem.Allocator.Error!Outcome {
        const key = try keyOf(self.allocator, identity);
        errdefer self.allocator.free(key);
        if (self.known.get(key)) |existing| {
            self.allocator.free(key);
            return existing;
        }
        const outcome = try self.build(file, start, end, offset);
        try self.known.put(self.allocator, key, outcome);
        return outcome;
    }

    fn build(self: *Registry, file: []const u8, start: u64, end: u64, offset: u64) std.mem.Allocator.Error!Outcome {
        var m = module.Module.load(self.allocator, file, start, end, offset) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoUnwindInfo => return .{ .unavailable = .no_unwind_info },
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer m.deinit(self.allocator);

        var table = compact.build(self.allocator, m.fdes) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .unavailable = .bad_unwind_info },
        };
        defer table.deinit(self.allocator);

        const id = self.set.add(table) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TableFull => return .{ .unavailable = .table_full },
            error.TooManyModules => return .{ .unavailable = .too_many_modules },
        };
        return .{ .loaded = .{ .id = id, .delta = start -% offset -% m.bias } };
    }
};

const testing = std.testing;

test "a file that cannot be used is remembered, and not parsed again" {
    var r = Registry.init(testing.allocator, 100, 4);
    defer r.deinit();
    const identity = Identity{ .build_id = &.{ 1, 2, 3 } };

    try testing.expect((try r.lookup(identity)) == null);
    const first = try r.add(identity, "this is not an ELF file", 0x1000, 0x2000, 0);
    try testing.expect(first == .unavailable);

    const again = (try r.lookup(identity)).?;
    try testing.expect(std.meta.eql(first, again));
    // A second add with the same identity answers from memory, whatever bytes it is given.
    const third = try r.add(identity, "", 0, 0, 0);
    try testing.expect(std.meta.eql(first, third));
    try testing.expectEqual(@as(usize, 0), r.set.modules.items.len);
}

test "the two kinds of identity do not collide" {
    var r = Registry.init(testing.allocator, 100, 4);
    defer r.deinit();
    _ = try r.add(.{ .build_id = "abc" }, "x", 0, 0, 0);
    try testing.expect((try r.lookup(.{ .build_id = "abc" })) != null);
    try testing.expect((try r.lookup(.{ .file = .{ .inode = 1, .path = "abc" } })) == null);
    try testing.expect((try r.lookup(.{ .build_id = "abd" })) == null);
}
