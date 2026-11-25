//! Saved runs: a profile kept on disk with a label, to look at again or compare later.
//!
//! Each run is two files in the runs directory: `<id>.meta.json`, small, for listing,
//! and `<id>.profile.json`, the profile as the caller encoded it. Files are written
//! to a temporary name and renamed, so a run is never seen half written.

const std = @import("std");
const shared = @import("shared");
const linux = std.os.linux;

const assert = std.debug.assert;
const File = shared.File;
const Directory = shared.directory.Directory;

pub const format = 1;
pub const label_bytes_max = 120;
pub const note_bytes_max = 2000;
const path_bytes_max = 4096;
const file_bytes_max = 512 * 1024 * 1024;
const runs_max = 4096;

pub const Error = error{
    OutOfMemory,
    NoDirectory,
    InvalidLabel,
    RunUnknown,
    Unreadable,
    Unwritable,
};

pub const Meta = struct {
    format: u32 = format,
    id: u64 = 0,
    label: []const u8,
    note: []const u8 = "",
    program: []const u8 = "",
    command: []const u8 = "",
    pid: u32 = 0,
    started_unix_ms: u64 = 0,
    elapsed_ms: u64 = 0,
    saved_unix_ms: u64 = 0,
    samples: u64 = 0,
    sample_hz: u32 = 0,
};

pub const Owner = struct {
    uid: u32,
    gid: u32,
    home: []const u8,
};

pub const StoreRuns = struct {
    dir: []const u8,
    owner: ?Owner = null,

    pub fn init(store: *StoreRuns, gpa: std.mem.Allocator, dir: ?[]const u8, owner: ?Owner) Error!void {
        const path = try dir_for(gpa, dir, owner);
        errdefer gpa.free(path);
        try dir_make(path, owner);
        store.* = .{ .dir = path, .owner = owner };
    }

    pub fn deinit(store: *StoreRuns, gpa: std.mem.Allocator) void {
        gpa.free(store.dir);
        store.* = undefined;
    }

    /// Keeps a profile under a new id; `meta.id` and `meta.saved_unix_ms` are set here.
    pub fn save(store: *const StoreRuns, arena: std.mem.Allocator, meta: Meta, profile_text: []const u8) Error!Meta {
        try label_check(meta.label, meta.note);
        var kept = meta;
        kept.saved_unix_ms = now_ms();
        kept.id = try store.id_new(arena, kept.saved_unix_ms);
        try store.write(arena, kept.id, "profile", profile_text);
        store.write(arena, kept.id, "meta", try json_of(arena, kept)) catch |err| {
            store.remove(arena, kept.id, "profile");
            return err;
        };
        return kept;
    }

    pub fn list(store: *const StoreRuns, arena: std.mem.Allocator) Error![]Meta {
        const path: [:0]u8 = try arena.dupeSentinel(u8, store.dir, 0);

        var directory = Directory.open(path) catch return error.NoDirectory;
        defer directory.deinit();
        var metas: std.ArrayList(Meta) = .empty;

        while (directory.next() catch return error.Unreadable) |name| {
            const id = id_of(name, ".meta.json") orelse continue;
            if (metas.items.len == runs_max) break;
            const found = store.info(arena, id) catch continue;
            try metas.append(arena, found);
        }
        std.mem.sortUnstable(Meta, metas.items, {}, newer);

        return metas.items;
    }

    pub fn info(store: *const StoreRuns, arena: std.mem.Allocator, id: u64) Error!Meta {
        const text = try store.read(arena, id, "meta");
        const parsed = std.json.parseFromSliceLeaky(Meta, arena, text, .{
            .ignore_unknown_fields = true,
        }) catch return error.Unreadable;
        if (parsed.id != id) return error.Unreadable;
        return parsed;
    }

    pub fn saved_profile(store: *const StoreRuns, arena: std.mem.Allocator, id: u64) Error![]const u8 {
        return store.read(arena, id, "profile");
    }

    pub fn relabel(store: *const StoreRuns, arena: std.mem.Allocator, id: u64, label: []const u8, note: []const u8) Error!Meta {
        try label_check(label, note);
        var changed = try store.info(arena, id);
        changed.label = label;
        changed.note = note;
        try store.write(arena, id, "meta", try json_of(arena, changed));
        return changed;
    }

    pub fn delete(store: *const StoreRuns, arena: std.mem.Allocator, id: u64) Error!void {
        _ = try store.info(arena, id);
        store.remove(arena, id, "meta");
        store.remove(arena, id, "profile");
    }

    fn id_new(store: *const StoreRuns, arena: std.mem.Allocator, now: u64) Error!u64 {
        var id = now;
        while (store.exists(arena, id)) id += 1;
        return id;
    }

    fn exists(store: *const StoreRuns, arena: std.mem.Allocator, id: u64) bool {
        const path = store.path_of(arena, id, "meta", "") catch return false;
        return linux.errno(linux.access(path, linux.F_OK)) == .SUCCESS;
    }

    fn remove(store: *const StoreRuns, arena: std.mem.Allocator, id: u64, kind: []const u8) void {
        const path = store.path_of(arena, id, kind, "") catch return;
        _ = linux.unlink(path);
    }

    fn write(store: *const StoreRuns, arena: std.mem.Allocator, id: u64, kind: []const u8, bytes: []const u8) Error!void {
        const temporary = try store.path_of(arena, id, kind, ".tmp");
        const path = try store.path_of(arena, id, kind, "");
        try file_write(temporary, bytes, store.owner);
        if (linux.errno(linux.rename(temporary, path)) != .SUCCESS) {
            _ = linux.unlink(temporary);
            return error.Unwritable;
        }
    }

    fn read(store: *const StoreRuns, arena: std.mem.Allocator, id: u64, kind: []const u8) Error![]u8 {
        const path = try store.path_of(arena, id, kind, "");
        var file = File.open(path) catch |err| return switch (err) {
            error.NotFound => error.RunUnknown,
            else => error.Unreadable,
        };
        defer file.deinit();
        const size = file.size_bytes() catch return error.Unreadable;
        if (size > file_bytes_max) return error.Unreadable;
        const bytes = try arena.alloc(u8, @intCast(size));
        const got = file.read_at(bytes, 0) catch return error.Unreadable;
        if (got != bytes.len) return error.Unreadable;
        return bytes;
    }

    fn dir_make(path: []const u8, owner: ?Owner) Error!void {
        if (path.len == 0 or path.len >= path_bytes_max or path[0] != '/') return error.NoDirectory;
        var buffer: [path_bytes_max]u8 = undefined;

        var end: usize = 1;
        while (end <= path.len) : (end += 1) {
            if (end != path.len and path[end] != '/') continue;
            @memcpy(buffer[0..end], path[0..end]);
            buffer[end] = 0;
            const made = linux.mkdir(buffer[0..end :0], 0o755);
            switch (linux.errno(made)) {
                .SUCCESS => if (owner) |user| {
                    _ = linux.chown(buffer[0..end :0], user.uid, user.gid);
                },
                .EXIST => {},
                else => return error.NoDirectory,
            }
        }
    }

    fn dir_for(gpa: std.mem.Allocator, dir: ?[]const u8, owner: ?Owner) Error![]const u8 {
        const user = owner orelse return dir_pick(gpa, dir);
        if (dir != null or env("NUSKU_RUNS_DIR") != null) return dir_pick(gpa, dir);
        return join(gpa, &.{ user.home, ".local/share/nusku/runs" });
    }

    fn dir_pick(gpa: std.mem.Allocator, dir: ?[]const u8) Error![]const u8 {
        if (dir) |given| return gpa.dupe(u8, given);
        if (env("NUSKU_RUNS_DIR")) |given| return gpa.dupe(u8, given);
        if (env("XDG_DATA_HOME")) |data| return join(gpa, &.{ data, "nusku/runs" });
        const home = env("HOME") orelse return error.NoDirectory;
        return join(gpa, &.{ home, ".local/share/nusku/runs" });
    }

    fn env(name: [*:0]const u8) ?[]const u8 {
        const value = std.mem.span(std.c.getenv(name) orelse return null);
        return if (value.len > 0 and value[0] == '/') value else null;
    }

    fn join(gpa: std.mem.Allocator, parts: []const []const u8) Error![]const u8 {
        return std.fs.path.join(gpa, parts) catch error.OutOfMemory;
    }

    fn path_of(store: *const StoreRuns, arena: std.mem.Allocator, id: u64, kind: []const u8, suffix: []const u8) Error![:0]const u8 {
        const args = .{ store.dir, id, kind, suffix };
        return std.fmt.allocPrintSentinel(arena, "{s}/{d}.{s}.json{s}", args, 0);
    }
};

pub fn sudo_owner(arena: std.mem.Allocator) ?Owner {
    if (linux.getuid() != 0) return null;
    const uid_text = std.mem.span(std.c.getenv("SUDO_UID") orelse return null);
    const uid = std.fmt.parseInt(u32, uid_text, 10) catch return null;

    if (uid == 0) return null;

    var file = File.open("/etc/passwd") catch return null;
    defer file.deinit();
    const bytes = arena.alloc(u8, 1 << 20) catch return null;
    const got = file.read_at(bytes, 0) catch return null;

    return passwd_find(bytes[0..got], uid);
}

/// name:password:uid:gid:gecos:home:shell
fn passwd_find(text: []const u8, uid: u32) ?Owner {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const found = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (found != uid) continue;
        const gid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        _ = fields.next() orelse continue;
        const home = fields.next() orelse continue;
        if (home.len == 0 or home[0] != '/') return null;
        return .{ .uid = uid, .gid = gid, .home = home };
    }
    return null;
}

fn label_check(label: []const u8, note: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    if (trimmed.len == 0 or label.len > label_bytes_max) return error.InvalidLabel;
    if (note.len > note_bytes_max) return error.InvalidLabel;
}

fn now_ms() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

fn newer(_: void, a: Meta, b: Meta) bool {
    return a.id > b.id;
}

fn id_of(name: []const u8, suffix: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - suffix.len], 10) catch null;
}

fn file_write(path: [:0]const u8, bytes: []const u8, owner: ?Owner) Error!void {
    const flags = linux.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.Unwritable;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    if (owner) |user| _ = linux.fchown(fd, user.uid, user.gid);
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => written += result,
            .INTR => continue,
            else => return error.Unwritable,
        }
    }
    if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.Unwritable;
}

fn json_of(arena: std.mem.Allocator, value: anytype) Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
}

const testing = std.testing;

fn store_test(store: *StoreRuns, arena: std.mem.Allocator) !void {
    const dir = try std.fmt.allocPrint(arena, "/tmp/nusku-runs-test-{d}/a/b", .{linux.getpid()});
    return store.init(arena, dir, null);
}

fn tree_remove(arena: std.mem.Allocator) void {
    const root = std.fmt.allocPrintSentinel(arena, "/tmp/nusku-runs-test-{d}", .{
        linux.getpid(),
    }, 0) catch return;
    var directory = Directory.open(std.fmt.allocPrintSentinel(arena, "{s}/a/b", .{root}, 0) catch
        return) catch return;
    defer directory.deinit();
    while (directory.next() catch null) |name| {
        if (name[0] == '.') continue;
        const path = std.fmt.allocPrintSentinel(arena, "{s}/a/b/{s}", .{ root, name }, 0) catch
            continue;
        _ = linux.unlink(path);
    }
    for ([_][]const u8{ "/a/b", "/a", "" }) |part| {
        const path = std.fmt.allocPrintSentinel(arena, "{s}{s}", .{ root, part }, 0) catch return;
        _ = linux.rmdir(path);
    }
}

test "a run is saved, listed newest first, read back, relabelled and deleted" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    defer tree_remove(arena);
    var store: StoreRuns = undefined;

    try store_test(&store, arena);

    const first = try store.save(arena, .{ .label = "v1", .program = "app", .samples = 9 }, "{}");
    const second = try store.save(arena, .{ .label = "v2", .note = "faster sort" }, "[1]");
    try testing.expect(second.id > first.id);
    try testing.expect(first.saved_unix_ms > 0);

    const listed = try store.list(arena);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("v2", listed[0].label);
    try testing.expectEqualStrings("faster sort", listed[0].note);
    try testing.expectEqualStrings("app", listed[1].program);
    try testing.expectEqual(@as(u64, 9), listed[1].samples);
    try testing.expectEqualStrings("[1]", try store.saved_profile(arena, second.id));

    const renamed = try store.relabel(arena, first.id, "v1, before", "sort then dedupe");
    try testing.expectEqualStrings("v1, before", renamed.label);
    try testing.expectEqualStrings("sort then dedupe", (try store.info(arena, first.id)).note);

    try store.delete(arena, first.id);
    try testing.expectError(error.RunUnknown, store.saved_profile(arena, first.id));
    try testing.expectError(error.RunUnknown, store.delete(arena, first.id));
    try testing.expectEqual(@as(usize, 1), (try store.list(arena)).len);
}

test "a run needs a label, and an unknown id is refused" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    defer tree_remove(arena);
    var store: StoreRuns = undefined;

    try store_test(&store, arena);

    try testing.expectError(error.InvalidLabel, store.save(arena, .{ .label = "  " }, "{}"));
    const long = "x" ** (label_bytes_max + 1);
    try testing.expectError(error.InvalidLabel, store.save(arena, .{ .label = long }, "{}"));
    try testing.expectError(error.RunUnknown, store.info(arena, 42));
    try testing.expectEqual(@as(usize, 0), (try store.list(arena)).len);
}

test "the user behind sudo is found by uid in the passwd file" {
    const text = "root:x:0:0:root:/root:/bin/bash\nali:x:1000:1000:Ali,,,:/home/ali:/bin/bash\n";
    const found = passwd_find(text, 1000).?;
    try testing.expectEqual(@as(u32, 1000), found.gid);
    try testing.expectEqualStrings("/home/ali", found.home);
    try testing.expect(passwd_find(text, 1001) == null);
}
