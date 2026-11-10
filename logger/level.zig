//! Severity levels.
const std = @import("std");

pub const Level = enum(u8) {
    trace,
    debug,
    info,
    warn,
    err,
    off,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
            .off => "off",
        };
    }

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .off => "OFF  ",
        };
    }

    pub fn parse(text: []const u8) ?Level {
        const table = [_]struct { []const u8, Level }{
            .{ "trace", .trace },
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "warning", .warn },
            .{ "error", .err },
            .{ "err", .err },
            .{ "off", .off },
            .{ "none", .off },
        };
        for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return null;
    }
};
