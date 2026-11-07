//! User names, from /etc/passwd: read once, then uid to name from memory.

const std = @import("std");
const File = @import("shared").File;

pub const Users = struct {
    /// The whole file: the names point into it.
    text: []u8 = &.{},
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    /// /etc/passwd is a few KiB; a file bigger than this is not a passwd file.
    const file_bytes_max = 4 * 1024 * 1024;

    pub fn load(users: *Users, gpa: std.mem.Allocator) !void {
        const text = file_read(gpa, "/etc/passwd") catch |err| switch (err) { // 1. no `try`
            error.OutOfMemory => return err,
            else => return,
        };
        users.text = text;
        errdefer users.deinit(gpa);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, ':');
            const name = fields.next() orelse continue;
            _ = fields.next() orelse continue; // password
            const uid_text = fields.next() orelse continue;
            if (name.len == 0) continue;
            const uid = std.fmt.parseInt(u32, uid_text, 10) catch continue;

            const slot = try users.names.getOrPut(gpa, uid);
            if (!slot.found_existing) slot.value_ptr.* = name;
        }
    }

    pub fn deinit(users: *Users, gpa: std.mem.Allocator) void {
        users.names.deinit(gpa);
        gpa.free(users.text);
        users.* = undefined;
    }

    /// The name of `uid`, or null when /etc/passwd does not list it. Good until `deinit`.
    pub fn get(users: *const Users, uid: u32) []const u8 {
        return users.names.get(uid) orelse "unknown";
    }

    fn file_read(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
        var file = try File.open(path);
        defer file.deinit();
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const len = try file.read(&chunk);
            if (len == 0) break;
            if (list.items.len + len > file_bytes_max) return error.TooLarge;
            try list.appendSlice(gpa, chunk[0..len]);
        }
        return list.toOwnedSlice(gpa);
    }
};

const testing = std.testing;

test "load reads /etc/passwd: uid 0 is root" {
    var users: Users = .{};
    try users.load(testing.allocator);
    defer users.deinit(testing.allocator);
    try testing.expectEqualStrings("root", users.get(0));
}

test "the user running the test has a name" {
    var users: Users = .{};
    try users.load(testing.allocator);
    defer users.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, users.get(std.os.linux.geteuid()), "unknown"));
}

test "a uid nobody has is unknown" {
    var users: Users = .{};
    try users.load(testing.allocator);
    defer users.deinit(testing.allocator);
    try testing.expectEqualStrings("unknown", users.get(std.math.maxInt(u32) - 1));
}
