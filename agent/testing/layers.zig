//! The rule of the layers, checked on the sources: a file of a layer imports its own layer, the
//! facades of the layers below it, the logger, and test helpers; nothing else. Two layers of
//! the same rank never import each other. Reads the sources from agent/, so it runs from the
//! repository's root (as `zig build test` does), and skips elsewhere.

const std = @import("std");
const File = @import("shared").File;
const Directory = @import("../os.zig").directory.Directory;

const Layer = struct { name: []const u8, rank: u8 };

/// Bottom up. ebpf, symbols and processes share a rank: none may use another.
const layers = [_]Layer{
    .{ .name = "os", .rank = 0 },
    .{ .name = "elf", .rank = 1 },
    .{ .name = "target", .rank = 2 },
    .{ .name = "unwind", .rank = 3 },
    .{ .name = "ebpf", .rank = 4 },
    .{ .name = "symbols", .rank = 4 },
    .{ .name = "processes", .rank = 4 },
};
/// The parent: run, watch, message and the root use the facades of every layer.
const parent_rank = 5;

const path_bytes_max = 512;
const source_bytes_max = 1 << 20;

/// The layer `path` (relative to agent/) belongs to: its facade or a file in its folder.
fn layer_of(path: []const u8) ?Layer {
    for (layers) |layer| {
        if (path.len < layer.name.len or !std.mem.startsWith(u8, path, layer.name)) continue;
        const rest = path[layer.name.len..];
        if (std.mem.eql(u8, rest, ".zig") or rest[0] == '/') return layer;
    }
    return null;
}

fn is_facade(path: []const u8, layer: Layer) bool {
    return path.len == layer.name.len + 4 and std.mem.endsWith(u8, path, ".zig");
}

/// Why `from` may not import `to`, or null when it may.
fn violation(from: []const u8, to: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, to, "log.zig")) return null;
    if (std.mem.startsWith(u8, to, "testing/")) return null; // Test helpers.
    const from_layer = layer_of(from);
    const to_layer = layer_of(to) orelse {
        if (from_layer == null) return null; // The parent among itself.
        return "a layer imports the parent";
    };
    if (from_layer) |layer| {
        if (std.mem.eql(u8, layer.name, to_layer.name)) return null; // Its own layer.
    }
    if (!is_facade(to, to_layer)) return "past another layer's facade";
    const rank = if (from_layer) |layer| layer.rank else parent_rank;
    if (to_layer.rank == rank) return "a layer beside it";
    if (to_layer.rank > rank) return "a layer above it";
    return null;
}

const Checker = struct {
    base: []const u8,
    found: u32 = 0,
    files: u32 = 0,

    /// Every .zig file under `directory` (relative to the base), recursively.
    fn walk(checker: *Checker, directory: []const u8) !void {
        var path_buffer: [path_bytes_max]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ checker.base, directory });
        var dir = try Directory.open(full);
        defer dir.deinit();
        while (try dir.next()) |name| {
            if (name[0] == '.' or std.mem.eql(u8, name, "testing")) continue;
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

    fn file_check(checker: *Checker, path: []const u8) !void {
        var path_buffer: [path_bytes_max]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ checker.base, path });
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
            if (violation(path, resolved)) |why| {
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

test "every layer imports only its own files and the facades below it" {
    var probe = File.open("agent/root.zig") catch return error.SkipZigTest;
    probe.deinit();
    var checker = Checker{ .base = "agent" };
    try checker.walk("");
    try std.testing.expect(checker.files > 50);
    try std.testing.expectEqual(@as(u32, 0), checker.found);
}

test "the rule: own layer, facades below, never beside or above" {
    try std.testing.expect(violation("ebpf/cpu/sampler.zig", "ebpf/bpf/map.zig") == null);
    try std.testing.expect(violation("ebpf.zig", "unwind.zig") == null);
    try std.testing.expect(violation("run.zig", "symbols.zig") == null);
    try std.testing.expect(violation("symbols/binary.zig", "ebpf.zig") != null); // Beside.
    try std.testing.expect(violation("target/vdso.zig", "unwind.zig") != null); // Above.
    try std.testing.expect(violation("unwind/module.zig", "target/process_maps.zig") != null);
    try std.testing.expect(violation("os/process.zig", "run.zig") != null); // The parent.
}
