//! A live profile kept up to date one report at a time, not rebuilt each time it is asked for

const std = @import("std");
const server_lib = @import("server");

const assert = std.debug.assert;

const Profile = server_lib.Profile;
const Frame = server_lib.Frame;
const SymbolStack = server_lib.SymbolStack;
const Names = server_lib.Names;
const Window = @typeInfo(@FieldType(Profile, "windows")).pointer.child;

const Key = struct {
    frames: []const Frame,
    complete: bool,
};

const Part = struct {
    start_unix_ns: u64,
    stacks: []const Counted,
};

const Counted = struct {
    key: Key,
    samples: u64,
};

const Total = struct {
    samples: u64,
    id: u32,
    stamp: u64,
};

/// The stacks that changed since `since`: their new counts, 0 for one gone, or all of them.
pub const Delta = struct {
    clock: u64,
    full: bool,
    ids: []const u32,
    profile: Profile,
};

/// Equal as merging sees it: the address counts only when there is no name.
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init(@intFromBool(key.complete));
        for (key.frames) |frame| {
            const parts = [_]u64{
                @intFromBool(frame.kernel) | @as(u64, @intFromBool(key.complete)) << 1,
                text_id(frame.module),
                text_id(frame.function),
                if (frame.function == null) frame.address else 0,
                text_id(frame.file),
                frame.line orelse 0,
            };
            hasher.update(std.mem.sliceAsBytes(&parts));
        }
        return hasher.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        if (a.complete != b.complete or a.frames.len != b.frames.len) return false;
        for (a.frames, b.frames) |x, y| {
            if (x.kernel != y.kernel or x.inlined != y.inlined) return false;
            if (text_id(x.module) != text_id(y.module)) return false;
            if (text_id(x.function) != text_id(y.function)) return false;
            if (x.function == null and x.address != y.address) return false;
            if (text_id(x.file) != text_id(y.file)) return false;
            if ((x.line orelse 0) != (y.line orelse 0)) return false;
        }
        return true;
    }
};

/// Strings are interned, so one string is one address.
fn text_id(text: ?[]const u8) u64 {
    return if (text) |value| @intFromPtr(value.ptr) else 0;
}

pub const ProfileCache = struct {
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    users: u32 = 0,
    orphaned: bool = false,
    generation: ?u64 = null,
    names: Names = .as_they_are,
    parts: std.ArrayList(Part) = .empty,
    pool: std.heap.ArenaAllocator,
    strings: std.StringHashMapUnmanaged([]const u8) = .empty,
    totals: std.HashMapUnmanaged(Key, Total, KeyContext, 80) = .empty,
    clock: u64 = 0,
    epoch: u64 = 0,
    stamp: u64 = 0,
    ids_next: u32 = 1,
    version: u64 = 0,

    pub fn create(gpa: std.mem.Allocator) !*ProfileCache {
        const cache = try gpa.create(ProfileCache);
        cache.* = .{ .pool = .init(gpa) };
        return cache;
    }

    pub fn update(cache: *ProfileCache, gpa: std.mem.Allocator, arena: std.mem.Allocator, server: *server_lib.Server, target: server_lib.TargetId, names: Names, summary: *const Profile, version: u64, since: u64) !Delta {
        assert(std.c.pthread_mutex_lock(&cache.lock) == .SUCCESS);
        defer assert(std.c.pthread_mutex_unlock(&cache.lock) == .SUCCESS);

        cache.stamp = cache.clock + 1;
        if (cache.generation != summary.names_generation or cache.names != names) {
            cache.reset(gpa);
            cache.epoch = cache.stamp;
            cache.generation = summary.names_generation;
            cache.names = names;
        }
        const first = if (summary.windows.len > 0) summary.windows[0].start_unix_ns else std.math.maxInt(u64);

        while (cache.parts.items.len > 0 and cache.parts.items[0].start_unix_ns < first) {
            const part = cache.parts.orderedRemove(0);
            cache.part_drop(gpa, part);
        }

        const last: ?u64 = if (cache.parts.getLastOrNull()) |part| part.start_unix_ns else null;
        for (summary.windows) |window| {
            if (last != null and window.start_unix_ns <= last.?) continue;
            try cache.part_add(gpa, server, target, window);
        }
        if (cache.version != version) cache.clock = cache.stamp;
        cache.version = version;
        const full = since < cache.epoch;
        var profile = summary.*;
        var ids: []u32 = &.{};

        profile.stacks = try cache.stacks(arena, if (full) null else since, &ids);
        return .{ .clock = cache.clock, .full = full, .ids = ids, .profile = profile };
    }

    /// Whether nothing changed since `since` for a profile at `version`.
    pub fn unchanged(cache: *ProfileCache, version: u64, since: u64) bool {
        assert(std.c.pthread_mutex_lock(&cache.lock) == .SUCCESS);
        defer assert(std.c.pthread_mutex_unlock(&cache.lock) == .SUCCESS);
        return cache.version == version and since == cache.clock and since >= cache.epoch;
    }

    pub fn deinit(cache: *ProfileCache, gpa: std.mem.Allocator) void {
        cache.reset(gpa);
        cache.parts.deinit(gpa);
        cache.strings.deinit(gpa);
        cache.totals.deinit(gpa);
        cache.pool.deinit();
        gpa.destroy(cache);
    }

    fn reset(cache: *ProfileCache, gpa: std.mem.Allocator) void {
        for (cache.parts.items) |part| gpa.free(part.stacks);
        cache.parts.clearRetainingCapacity();
        cache.totals.clearRetainingCapacity();
        cache.strings.clearRetainingCapacity();
        _ = cache.pool.reset(.retain_capacity);
        cache.generation = null;
        cache.ids_next = 1;
    }

    fn part_drop(cache: *ProfileCache, gpa: std.mem.Allocator, part: Part) void {
        for (part.stacks) |stack| {
            const total = cache.totals.getPtr(stack.key) orelse continue;
            total.samples -|= stack.samples;
            total.stamp = cache.stamp;
        }
        gpa.free(part.stacks);
    }

    fn part_add(cache: *ProfileCache, gpa: std.mem.Allocator, server: *server_lib.Server, target: server_lib.TargetId, window_wanted: Window) !void {
        const start = window_wanted.start_unix_ns;
        const middle = start +| window_wanted.duration_ns / 2;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const query = server_lib.Query{
            .target = target,
            .from_unix_ns = middle,
            .to_unix_ns = middle + 1,
        };
        const window = try server.profile(scratch.allocator(), query, cache.names);

        const counted = try gpa.alloc(Counted, window.stacks.len);
        errdefer gpa.free(counted);
        for (window.stacks, counted) |stack, *out| {
            const key = try cache.key_of(gpa, scratch.allocator(), stack);
            const entry = try cache.totals.getOrPut(gpa, key);
            if (!entry.found_existing) {
                const frames = try cache.pool.allocator().dupe(Frame, key.frames);
                entry.key_ptr.* = .{ .frames = frames, .complete = key.complete };
                entry.value_ptr.* = .{ .samples = 0, .id = cache.ids_next, .stamp = 0 };
                cache.ids_next += 1;
            }
            entry.value_ptr.samples += stack.samples;
            entry.value_ptr.stamp = cache.stamp;
            out.* = .{ .key = entry.key_ptr.*, .samples = stack.samples };
        }

        try cache.parts.append(gpa, .{ .start_unix_ns = start, .stacks = counted });
    }

    fn key_of(cache: *ProfileCache, gpa: std.mem.Allocator, scratch: std.mem.Allocator, stack: SymbolStack) !Key {
        const frames = try scratch.alloc(Frame, stack.frames.len);
        for (stack.frames, frames) |frame, *out| {
            out.* = frame;
            out.function = try cache.intern(gpa, frame.function);
            out.file = try cache.intern(gpa, frame.file);
            out.module = try cache.intern(gpa, frame.module);
        }
        return .{ .frames = frames, .complete = stack.complete };
    }

    fn intern(cache: *ProfileCache, gpa: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
        const value = text orelse return null;
        const entry = try cache.strings.getOrPut(gpa, value);
        if (!entry.found_existing) {
            const copy = try cache.pool.allocator().dupe(u8, value);
            entry.key_ptr.* = copy;
            entry.value_ptr.* = copy;
        }
        return entry.value_ptr.*;
    }

    fn stacks(cache: *ProfileCache, arena: std.mem.Allocator, since: ?u64, ids: *[]u32) ![]SymbolStack {
        var count: usize = 0;
        var counting = cache.totals.valueIterator();
        while (counting.next()) |total| count += @intFromBool(wanted(total, since));
        const out = try arena.alloc(SymbolStack, count);
        ids.* = try arena.alloc(u32, count);
        var filled: usize = 0;
        var entries = cache.totals.iterator();
        while (entries.next()) |entry| {
            if (!wanted(entry.value_ptr, since)) continue;
            out[filled] = .{
                .samples = entry.value_ptr.samples,
                .frames = entry.key_ptr.frames,
                .complete = entry.key_ptr.complete,
            };
            ids.*[filled] = entry.value_ptr.id;
            filled += 1;
        }
        return out;
    }
};

fn wanted(total: *const Total, since: ?u64) bool {
    const after = since orelse return total.samples > 0;
    return total.stamp > after;
}

const testing = std.testing;

test "ProfileCache create and destroy" {
    var cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), cache.ids_next);
    try testing.expectEqual(@as(u64, 0), cache.clock);
    try testing.expectEqual(@as(u64, 0), cache.epoch);
    try testing.expectEqual(@as(?u64, null), cache.generation);
    try testing.expectEqual(@as(usize, 0), cache.parts.items.len);
    try testing.expectEqual(@as(usize, 0), cache.totals.count());
}

test "ProfileCache unchanged checks version and clock" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    cache.version = 10;
    cache.clock = 5;
    cache.epoch = 2;

    try testing.expect(cache.unchanged(10, 5));
    try testing.expect(!cache.unchanged(9, 5));
    try testing.expect(!cache.unchanged(10, 4));
    try testing.expect(!cache.unchanged(10, 6));
    try testing.expect(!cache.unchanged(10, 1));
}

test "ProfileCache intern reuses strings" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    const first = try cache.intern(testing.allocator, "hello");
    const second = try cache.intern(testing.allocator, "hello");
    const third = try cache.intern(testing.allocator, "world");

    try std.testing.expectEqualStrings("hello", first.?);
    try std.testing.expectEqualStrings("hello", second.?);
    try std.testing.expectEqualStrings("world", third.?);

    try std.testing.expectEqual(
        @intFromPtr(first.?.ptr),
        @intFromPtr(second.?.ptr),
    );

    try std.testing.expect(@intFromPtr(first.?.ptr) != @intFromPtr(third.?.ptr));
    try std.testing.expectEqual(@as(usize, 2), cache.strings.count());
}

test "ProfileCache intern handles null" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    const result = try cache.intern(testing.allocator, null);

    try testing.expect(result == null);
    try testing.expectEqual(@as(usize, 0), cache.strings.count());
}

test "ProfileCache key_of handles empty stack" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const key = try cache.key_of(testing.allocator, scratch.allocator(), .{
        .samples = 10,
        .frames = &.{},
        .complete = true,
    });

    try std.testing.expectEqual(@as(usize, 0), key.frames.len);
    try std.testing.expect(key.complete);
}

test "ProfileCache stacks returns active stacks for full snapshot" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    const active_key = Key{
        .frames = &.{},
        .complete = true,
    };
    const removed_key = Key{
        .frames = &.{},
        .complete = false,
    };

    try cache.totals.put(testing.allocator, active_key, .{
        .samples = 10,
        .id = 1,
        .stamp = 1,
    });

    try cache.totals.put(testing.allocator, removed_key, .{
        .samples = 0,
        .id = 2,
        .stamp = 2,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ids: []u32 = &.{};
    const result = try cache.stacks(arena.allocator(), null, &ids);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqual(@as(u64, 10), result[0].samples);
    try testing.expectEqual(@as(u32, 1), ids[0]);
}

test "ProfileCache stacks returns only changed stacks" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    try cache.totals.put(testing.allocator, .{
        .frames = &.{},
        .complete = true,
    }, .{
        .samples = 10,
        .id = 1,
        .stamp = 2,
    });

    try cache.totals.put(testing.allocator, .{
        .frames = &.{},
        .complete = false,
    }, .{
        .samples = 20,
        .id = 2,
        .stamp = 5,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ids: []u32 = &.{};
    const result = try cache.stacks(arena.allocator(), 3, &ids);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u32, 2), ids[0]);
    try testing.expectEqual(@as(u64, 20), result[0].samples);
}

test "ProfileCache stacks includes removed stacks in incremental updates" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    try cache.totals.put(testing.allocator, .{
        .frames = &.{},
        .complete = true,
    }, .{
        .samples = 0,
        .id = 7,
        .stamp = 5,
    });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ids: []u32 = &.{};
    const result = try cache.stacks(arena.allocator(), 3, &ids);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u64, 0), result[0].samples);
    try testing.expectEqual(@as(u32, 7), ids[0]);
}

test "ProfileCache part_drop subtracts window samples" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    const key = Key{
        .frames = &.{},
        .complete = true,
    };

    try cache.totals.put(testing.allocator, key, .{
        .samples = 30,
        .id = 1,
        .stamp = 1,
    });

    const counted = try testing.allocator.alloc(Counted, 1);
    counted[0] = .{
        .key = key,
        .samples = 10,
    };

    cache.stamp = 5;
    cache.part_drop(testing.allocator, .{
        .start_unix_ns = 100,
        .stacks = counted,
    });

    const total = cache.totals.get(key).?;
    try testing.expectEqual(@as(u64, 20), total.samples);
    try testing.expectEqual(@as(u64, 5), total.stamp);
}

test "ProfileCache part_drop removes all samples without underflow" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    const key = Key{
        .frames = &.{},
        .complete = true,
    };

    try cache.totals.put(testing.allocator, key, .{
        .samples = 5,
        .id = 1,
        .stamp = 1,
    });

    const counted = try testing.allocator.alloc(Counted, 1);
    counted[0] = .{
        .key = key,
        .samples = 10,
    };

    cache.stamp = 8;
    cache.part_drop(testing.allocator, .{
        .start_unix_ns = 100,
        .stacks = counted,
    });

    const total = cache.totals.get(key).?;
    try std.testing.expectEqual(@as(u64, 0), total.samples);
    try std.testing.expectEqual(@as(u64, 8), total.stamp);
}

test "ProfileCache reset clears cached state" {
    const cache = try ProfileCache.create(testing.allocator);
    defer cache.deinit(testing.allocator);

    _ = try cache.intern(testing.allocator, "function");

    const key = Key{
        .frames = &.{},
        .complete = true,
    };

    try cache.totals.put(testing.allocator, key, .{
        .samples = 10,
        .id = 5,
        .stamp = 3,
    });

    const counted = try testing.allocator.alloc(Counted, 1);
    counted[0] = .{
        .key = key,
        .samples = 10,
    };

    try cache.parts.append(testing.allocator, .{
        .start_unix_ns = 100,
        .stacks = counted,
    });

    cache.generation = 42;
    cache.ids_next = 6;

    cache.reset(testing.allocator);

    try testing.expectEqual(@as(usize, 0), cache.parts.items.len);
    try testing.expectEqual(@as(usize, 0), cache.totals.count());
    try testing.expectEqual(@as(usize, 0), cache.strings.count());
    try testing.expectEqual(@as(?u64, null), cache.generation);
    try testing.expectEqual(@as(u32, 1), cache.ids_next);
}

test "KeyContext eql compares completeness" {
    const a = Key{
        .frames = &.{},
        .complete = true,
    };

    const b = Key{
        .frames = &.{},
        .complete = false,
    };

    try testing.expect(!KeyContext.eql(.{}, a, b));
}

test "KeyContext hash is consistent for equal keys" {
    const a = Key{
        .frames = &.{},
        .complete = true,
    };

    const b = Key{
        .frames = &.{},
        .complete = true,
    };

    try std.testing.expect(KeyContext.eql(.{}, a, b));
    try std.testing.expectEqual(
        KeyContext.hash(.{}, a),
        KeyContext.hash(.{}, b),
    );
}

test "wanted handles full and incremental snapshots" {
    const active = Total{
        .samples = 10,
        .id = 1,
        .stamp = 5,
    };

    const removed = Total{
        .samples = 0,
        .id = 2,
        .stamp = 6,
    };

    try std.testing.expect(wanted(&active, null));
    try std.testing.expect(!wanted(&removed, null));

    try std.testing.expect(!wanted(&active, 5));
    try std.testing.expect(wanted(&active, 4));

    try std.testing.expect(wanted(&removed, 5));
    try std.testing.expect(!wanted(&removed, 6));
}
