//! libdebuginfod, loaded when first needed

const std = @import("std");
const log = @import("../log.zig").server;
const File = @import("shared").File;

const Client = opaque {};
const Progress = *const fn (client: *Client, a: c_long, b: c_long) callconv(.c) c_int;
const Begin = *const fn () callconv(.c) ?*Client;
const FindSection = *const fn (
    *Client,
    [*]const u8,
    c_int,
    [*:0]const u8,
    *?[*:0]u8,
) callconv(.c) c_int;
const FindDebuginfo = *const fn (*Client, [*]const u8, c_int, *?[*:0]u8) callconv(.c) c_int;
const End = *const fn (*Client) callconv(.c) void;
const SetProgress = *const fn (*Client, Progress) callconv(.c) void;

pub const Library = struct {
    handle: *anyopaque,
    client: *Client,
    find_section: FindSection,
    find_debuginfo: FindDebuginfo,
    end: End,

    pub fn init() ?Library {
        const handle = std.c.dlopen("libdebuginfod.so.1", .{ .NOW = true }) orelse {
            log.info("debug symbols are not downloaded: libdebuginfod cannot be loaded", .{});
            return null;
        };
        const begin = symbol(handle, "debuginfod_begin", Begin);
        const find_section = symbol(handle, "debuginfod_find_section", FindSection);
        const find_debuginfo = symbol(handle, "debuginfod_find_debuginfo", FindDebuginfo);
        const end = symbol(handle, "debuginfod_end", End);
        const progress = symbol(handle, "debuginfod_set_progressfn", SetProgress);
        const missing = begin == null or find_section == null or find_debuginfo == null;
        if (missing or end == null or progress == null) {
            _ = std.c.dlclose(handle);
            return null;
        }
        const client = begin.?() orelse {
            _ = std.c.dlclose(handle);
            return null;
        };
        progress.?(client, progress_check);
        return .{
            .handle = handle,
            .client = client,
            .find_section = find_section.?,
            .find_debuginfo = find_debuginfo.?,
            .end = end.?,
        };
    }

    pub fn debuginfo(library: *Library, gpa: std.mem.Allocator, build_id: []const u8) ?[]u8 {
        var path: ?[*:0]u8 = null;
        fetch_started_s = now_s();
        const id_len: c_int = @intCast(build_id.len);
        const fd = library.find_debuginfo(library.client, build_id.ptr, id_len, &path);
        defer if (path) |owned| std.c.free(owned);
        if (fd < 0) return null;
        _ = std.c.close(fd);
        return file_read(gpa, std.mem.span(path orelse return null));
    }

    pub fn section(
        library: *Library,
        gpa: std.mem.Allocator,
        build_id: []const u8,
        name: [*:0]const u8,
    ) ?[]u8 {
        var path: ?[*:0]u8 = null;
        fetch_started_s = now_s();
        const id_len: c_int = @intCast(build_id.len);
        const fd = library.find_section(library.client, build_id.ptr, id_len, name, &path);
        defer if (path) |owned| std.c.free(owned);
        if (fd < 0) return null;
        _ = std.c.close(fd);
        return file_read(gpa, std.mem.span(path orelse return null));
    }

    pub fn deinit(library: *Library) void {
        library.end(library.client);
        _ = std.c.dlclose(library.handle);
        library.* = undefined;
    }
};

fn symbol(handle: *anyopaque, name: [*:0]const u8, comptime T: type) ?T {
    const found = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(found));
}

const fetch_seconds_max = 15;
threadlocal var fetch_started_s: i64 = 0;
const file_bytes_max = 128 * 1024 * 1024;

fn progress_check(client: *Client, done: c_long, total: c_long) callconv(.c) c_int {
    _ = client;
    _ = done;
    _ = total;
    return @intFromBool(now_s() - fetch_started_s > fetch_seconds_max);
}

fn now_s() i64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return now.sec;
}

/// A file debuginfod downloaded into the server's own cache.
fn file_read(gpa: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    var file = File.open(path) catch return null;
    defer file.deinit();
    const size = file.size_bytes() catch return null;
    if (size == 0 or size > file_bytes_max) return null;
    const bytes = gpa.alloc(u8, @intCast(size)) catch return null;
    const got = file.read_at(bytes, 0) catch {
        gpa.free(bytes);
        return null;
    };
    if (got != bytes.len) {
        gpa.free(bytes);
        return null;
    }
    return bytes;
}
