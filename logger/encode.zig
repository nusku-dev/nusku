//! Turns one log record into bytes.

const std = @import("std");
const Writer = std.Io.Writer;
const Level = @import("level.zig").Level;
const time = @import("time.zig");

pub const Format = enum { text, logfmt, json };

const ansi_reset = "\x1b[0m";
const ansi_dim = "\x1b[2m";

fn levelColor(level: Level) []const u8 {
    return switch (level) {
        .trace => "\x1b[90m",
        .debug => "\x1b[36m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
        .off => "",
    };
}

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct {
        a: A,
        b: B,
        pub const log_pair = true;
    };
}

pub fn writeRecord(
    w: *Writer,
    format: Format,
    color: bool,
    timestamp_ns: ?i96,
    level: Level,
    scope: []const u8,
    msg: []const u8,
    fields: anytype,
) Writer.Error!void {
    switch (format) {
        .text => {
            if (timestamp_ns) |t| {
                if (color) try w.writeAll(ansi_dim);
                try time.writeRfc3339(w, t);
                if (color) try w.writeAll(ansi_reset);
                try w.writeByte(' ');
            }
            if (color) try w.writeAll(levelColor(level));
            try w.writeAll(level.label());
            if (color) try w.writeAll(ansi_reset);
            try w.writeByte(' ');
            if (scope.len > 0) {
                try writeSingleLine(w, scope);
                try w.writeAll(": ");
            }
            try writeSingleLine(w, msg);
        },
        .logfmt => {
            if (timestamp_ns) |t| {
                try w.writeAll("time=");
                try time.writeRfc3339(w, t);
                try w.writeByte(' ');
            }
            try w.print("level={s}", .{level.name()});
            if (scope.len > 0) {
                try w.writeAll(" scope=");
                try writeLogfmtString(w, scope);
            }
            try w.writeAll(" msg=");
            try writeLogfmtString(w, msg);
        },
        .json => {
            try w.writeByte('{');
            if (timestamp_ns) |t| {
                try w.writeAll("\"time\":\"");
                try time.writeRfc3339(w, t);
                try w.writeAll("\",");
            }
            try w.print("\"level\":\"{s}\"", .{level.name()});
            if (scope.len > 0) {
                try w.writeAll(",\"scope\":");
                try writeJsonString(w, scope);
            }
            try w.writeAll(",\"msg\":");
            try writeJsonString(w, msg);
        },
    }
    try writeFields(w, format, color, fields);
    if (format == .json) try w.writeByte('}');
    try w.writeByte('\n');
}

pub fn writeFields(w: *Writer, format: Format, color: bool, fields: anytype) Writer.Error!void {
    const T = @TypeOf(fields);
    const info = @typeInfo(T);
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".fields.len > 0)) {
        @compileError("log fields must be a struct with named fields, like .{ .key = value }");
    }
    if (@hasDecl(T, "log_pair")) {
        try writeFields(w, format, color, fields.a);
        try writeFields(w, format, color, fields.b);
        return;
    }
    inline for (info.@"struct".fields) |f| {
        try writeField(w, format, color, f.name, @field(fields, f.name));
    }
}

fn writeField(w: *Writer, format: Format, color: bool, comptime key: []const u8, value: anytype) Writer.Error!void {
    if (format == .json) {
        try w.writeByte(',');
        try writeJsonString(w, key);
        try w.writeByte(':');
    } else {
        try w.writeByte(' ');
        if (color) try w.writeAll(ansi_dim);
        try w.writeAll(key);
        try w.writeByte('=');
        if (color) try w.writeAll(ansi_reset);
    }
    try writeValue(w, format, value);
}

fn isString(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice) return p.child == u8;
            if (p.size == .one) {
                const child = @typeInfo(p.child);
                return child == .array and child.array.child == u8;
            }
            return false;
        },
        .array => |a| return a.child == u8,
        else => return false,
    }
}

fn writeValue(w: *Writer, format: Format, value: anytype) Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime isString(T)) {
        const s: []const u8 = if (comptime @typeInfo(T) == .array) &value else value;
        return writeString(w, format, s);
    }
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => {
            const f: f64 = value;
            if (format == .json and !std.math.isFinite(f)) {
                try w.writeAll("null");
            } else {
                try w.print("{d}", .{f});
            }
        },
        .@"enum", .enum_literal => try writeString(w, format, @tagName(value)),
        .error_set => try writeString(w, format, @errorName(value)),
        .optional => if (value) |inner| {
            try writeValue(w, format, inner);
        } else {
            try w.writeAll("null");
        },
        .null => try w.writeAll("null"),
        else => {
            var buf: [512]u8 = undefined;
            var fw: Writer = .fixed(&buf);
            fw.print("{any}", .{value}) catch {};
            try writeString(w, format, fw.buffered());
        },
    }
}

fn writeString(w: *Writer, format: Format, s: []const u8) Writer.Error!void {
    if (format == .json) return writeJsonString(w, s);
    return writeLogfmtString(w, s);
}

fn needsQuote(s: []const u8) bool {
    if (s.len == 0) return true;
    for (s) |c| {
        if (c <= ' ' or c == '"' or c == '=' or c == '\\' or c == 0x7f) return true;
    }
    return false;
}

fn writeLogfmtString(w: *Writer, s: []const u8) Writer.Error!void {
    if (!needsQuote(s)) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeSingleLine(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
}
