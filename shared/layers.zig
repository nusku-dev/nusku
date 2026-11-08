//! The rule of the layers, checked on the sources. A module made of layers lists them with a
//! rank; then a file of a layer imports only its own layer, the facades of the layers below it,
//! the logger, and test helpers. Layers of the same rank never import each other. A file in no
//! layer (the module's parent) may import every facade.
//!
//!     try layers.check(.{ .base = "agent", .layers = &.{ .{ .name = "os", .rank = 0 }, ... } });
//!
//! Reads the sources from the working directory: the repository's root, as `zig build test`
//! runs.

const std = @import("std");
const File = @import("file.zig").File;
const Directory = @import("directory.zig").Directory;

pub const Layer = struct { name: []const u8, rank: u8 };

pub const Rules = struct {
    /// The module's folder, from the repository's root.
    base: []const u8,
    /// Bottom up.
    layers: []const Layer,
    /// Folders not checked: test helpers, and whatever is not the module's code.
    skipped: []const []const u8 = &.{"testing"},
    /// The module's root file, which says the sources are there.
    root: []const u8 = "root.zig",
};

const path_bytes_max = 512;
const source_bytes_max = 1 << 20;

/// Every import that breaks the rules, printed with its file. `error.SkipZigTest` when the
/// sources are not where `base` says: the tests run from elsewhere.
pub fn check(rules: Rules) !u32 {
    var path_buffer: [path_bytes_max]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ rules.base, rules.root });
    var probe = File.open(root) catch return error.SkipZigTest;
    probe.deinit();
    var checker = Checker{ .rules = rules };
    try checker.walk("");
    if (checker.files == 0) return error.NoSources;
    return checker.found;
}

/// The layer `path` belongs to: its facade or a file in its folder.
fn layer_of(rules: Rules, path: []const u8) ?Layer {
    for (rules.layers) |layer| {
        if (path.len <= layer.name.len or !std.mem.startsWith(u8, path, layer.name)) continue;
        const rest = path[layer.name.len..];
        if (std.mem.eql(u8, rest, ".zig") or rest[0] == '/') return layer;
    }
    return null;
}

fn is_facade(path: []const u8, layer: Layer) bool {
    return path.len == layer.name.len + 4 and std.mem.endsWith(u8, path, ".zig");
}

/// Why `from` may not import `to`, or null when it may.
fn violation(rules: Rules, from: []const u8, to: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, to, "log.zig")) return null;
    for (rules.skipped) |folder| {
        if (std.mem.startsWith(u8, to, folder) and to.len > folder.len and to[folder.len] == '/')
            return null; // Test helpers.
    }
    const from_layer = layer_of(rules, from);
    const to_layer = layer_of(rules, to) orelse {
        if (from_layer == null) return null; // The parent among itself.
        return "a layer imports the parent";
    };
    const from_found = from_layer orelse {
        return if (is_facade(to, to_layer)) null else "past another layer's facade";
    };
    if (std.mem.eql(u8, from_found.name, to_layer.name)) return null; // Its own layer.
    if (!is_facade(to, to_layer)) return "past another layer's facade";
    if (to_layer.rank == from_found.rank) return "a layer beside it";
    if (to_layer.rank > from_found.rank) return "a layer above it";
    return null;
}

const Checker = struct {
    rules: Rules,
    found: u32 = 0,
    files: u32 = 0,

    /// Every .zig file under `directory` (relative to the base), recursively.
    fn walk(checker: *Checker, directory: []const u8) !void {
        var path_buffer: [path_bytes_max]u8 = undefined;
        const base = checker.rules.base;
        const full = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ base, directory });
        var dir = try Directory.open(full);
        defer dir.deinit();
        while (try dir.next()) |name| {
            if (name[0] == '.' or checker.skipped(name, directory)) continue;
            var child_buffer: [path_bytes_max]u8 = undefined;
            const child = if (directory.len == 0)
                try std.fmt.bufPrint(&child_buffer, "{s}", .{name})
            else
                try std.fmt.bufPrint(&child_buffer, "{s}/{s}", .{ directory, name });
            if (std.mem.endsWith(u8, name, ".zig")) {
                if (std.mem.eql(u8, child, "build.zig")) continue;
                try checker.file_check(child);
            } else if (std.mem.indexOfScalar(u8, name, '.') == null) {
                try checker.walk(child);
            }
        }
    }

    fn skipped(checker: *const Checker, name: []const u8, directory: []const u8) bool {
        if (directory.len > 0) return false;
        for (checker.rules.skipped) |folder| {
            if (std.mem.eql(u8, name, folder)) return true;
        }
        return false;
    }

    fn file_check(checker: *Checker, path: []const u8) !void {
        var path_buffer: [path_bytes_max]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ checker.rules.base, path });
        var file = try File.open(full);
        defer file.deinit();
        const source = try std.testing.allocator.alloc(u8, source_bytes_max);
        defer std.testing.allocator.free(source);
        const source_len = try file.read_at(source, 0);
        checker.files += 1;

        const needle = "@import(\"";
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source[0..source_len], at, needle)) |start| {
            const name_start = start + needle.len;
            const text = source[0..source_len];
            const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"') orelse break;
            at = name_end;
            const name = source[name_start..name_end];
            if (!std.mem.endsWith(u8, name, ".zig")) continue; // A module: std, shared, ...
            var resolved_buffer: [path_bytes_max]u8 = undefined;
            const resolved = resolve(&resolved_buffer, path, name) orelse continue;
            if (violation(checker.rules, path, resolved)) |why| {
                std.debug.print("layers: {s} imports {s}: {s}\n", .{ path, resolved, why });
                checker.found += 1;
            }
        }
    }
};

/// `name`, imported from `from`, as a path relative to agent/. Null when it leaves agent/.
fn resolve(buffer: []u8, from: []const u8, name: []const u8) ?[]const u8 {
    var parts: [32][]const u8 = undefined;
    var count: usize = 0;
    var from_parts = std.mem.splitScalar(u8, from, '/');
    while (from_parts.next()) |part| : (count += 1) parts[count] = part;
    count -= 1; // The file itself.
    var name_parts = std.mem.splitScalar(u8, name, '/');
    while (name_parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return null;
            count -= 1;
            continue;
        }
        parts[count] = part;
        count += 1;
    }
    var length: usize = 0;
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) {
            buffer[length] = '/';
            length += 1;
        }
        @memcpy(buffer[length..][0..part.len], part);
        length += part.len;
    }
    return buffer[0..length];
}

// ------------------------------------------------------------------------------------- tests

const rules_test = Rules{ .base = "", .layers = &.{
    .{ .name = "os", .rank = 0 },
    .{ .name = "target", .rank = 1 },
    .{ .name = "ebpf", .rank = 2 },
    .{ .name = "symbols", .rank = 2 },
} };

test "the rule: own layer, facades below, never beside or above" {
    const r = rules_test;
    try std.testing.expect(violation(r, "ebpf/cpu/sampler.zig", "ebpf/bpf/map.zig") == null);
    try std.testing.expect(violation(r, "ebpf.zig", "target.zig") == null);
    try std.testing.expect(violation(r, "run.zig", "symbols.zig") == null);
    try std.testing.expect(violation(r, "symbols/binary.zig", "ebpf.zig") != null); // Beside.
    try std.testing.expect(violation(r, "os/process.zig", "target.zig") != null); // Above.
    try std.testing.expect(violation(r, "ebpf/x.zig", "target/maps.zig") != null); // Past.
    try std.testing.expect(violation(r, "os/process.zig", "run.zig") != null); // The parent.
    try std.testing.expect(violation(r, "run.zig", "target/maps.zig") != null); // Past.
    try std.testing.expect(violation(r, "os/process.zig", "testing/process.zig") == null);
}
