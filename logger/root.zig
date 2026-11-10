//! Public API of the log module.

const std = @import("std");
const logger_mod = @import("logger.zig");
const encode = @import("encode.zig");

pub const Level = @import("level.zig").Level;
pub const Format = encode.Format;
pub const Logger = logger_mod.Logger;
pub const Options = logger_mod.Options;
pub const Bound = logger_mod.Bound;

pub const setDefault = logger_mod.setDefault;
pub const clearDefault = logger_mod.clearDefault;
pub const getDefault = logger_mod.getDefault;
pub const shouldColor = logger_mod.shouldColor;

pub fn emit(level: Level, msg: []const u8, fields: anytype) void {
    const lg = getDefault() orelse return;
    lg.emit(level, "", msg, fields);
}
pub fn trace(msg: []const u8, fields: anytype) void {
    emit(.trace, msg, fields);
}
pub fn debug(msg: []const u8, fields: anytype) void {
    emit(.debug, msg, fields);
}
pub fn info(msg: []const u8, fields: anytype) void {
    emit(.info, msg, fields);
}
pub fn warn(msg: []const u8, fields: anytype) void {
    emit(.warn, msg, fields);
}
pub fn err(msg: []const u8, fields: anytype) void {
    emit(.err, msg, fields);
}

pub fn scope(name: []const u8) Bound(struct {}) {
    return .{ .scope_name = name, .fields = .{} };
}

pub fn with(fields: anytype) Bound(@TypeOf(fields)) {
    return .{ .fields = fields };
}

pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope_tag: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const lg = getDefault() orelse return;
    const mapped: Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    if (!lg.enabled(mapped)) return;

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {};
    const name = if (scope_tag == .default) "" else @tagName(scope_tag);
    lg.emit(mapped, name, w.buffered(), .{});
}

test "global functions and std.log bridge" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var lg: Logger = .init(.{ .writer = &out.writer, .io = std.testing.io, .timestamps = false, .level = .debug });

    clearDefault();
    info("nobody listens", .{});

    setDefault(&lg);
    defer clearDefault();

    info("started", .{ .port = 7000 });
    stdLogFn(.warn, .default, "disk {d}% full", .{90});
    stdLogFn(.debug, .netsy, "retry {s}", .{"soon"});
    try std.testing.expectEqualStrings(
        "INFO  started port=7000\n" ++
            "WARN  disk 90% full\n" ++
            "DEBUG netsy: retry soon\n",
        out.written(),
    );
}
