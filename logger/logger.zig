//! The Logger: owns the output writer.
const std = @import("std");
const Writer = std.Io.Writer;
const Level = @import("level.zig").Level;
const encode = @import("encode.zig");
const Format = encode.Format;

pub const Options = struct {
    writer: *Writer,
    io: std.Io,
    level: Level = .info,
    format: Format = .text,
    color: bool = false,
    timestamps: bool = true,
    flush: bool = true,
    now_fn: ?*const fn () i96 = null,
};

pub const Logger = struct {
    writer: *Writer,
    io: std.Io,
    level: std.atomic.Value(Level),
    format: Format,
    color: bool,
    timestamps: bool,
    flush_each: bool,
    now_fn: ?*const fn () i96,
    mutex: std.Io.Mutex = .init,

    pub fn init(opts: Options) Logger {
        return .{
            .writer = opts.writer,
            .io = opts.io,
            .level = .init(opts.level),
            .format = opts.format,
            .color = opts.color,
            .timestamps = opts.timestamps,
            .flush_each = opts.flush,
            .now_fn = opts.now_fn,
        };
    }

    // Safe to call from any thread.

    pub fn setLevel(self: *Logger, level: Level) void {
        self.level.store(level, .monotonic);
    }

    pub fn getLevel(self: *const Logger) Level {
        return self.level.load(.monotonic);
    }

    pub fn setFormat(self: *Logger, format: Format) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.format = format;
    }

    pub fn setColor(self: *Logger, color: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.color = color;
    }

    pub fn enabled(self: *const Logger, level: Level) bool {
        return level != .off and @intFromEnum(level) >= @intFromEnum(self.getLevel());
    }

    pub fn emit(self: *Logger, level: Level, scope_name: []const u8, msg: []const u8, fields: anytype) void {
        if (!self.enabled(level)) return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const ts: ?i96 = if (self.timestamps) self.now() else null;
        encode.writeRecord(self.writer, self.format, self.color, ts, level, scope_name, msg, fields) catch {};
        if (self.flush_each) self.writer.flush() catch {};
    }

    fn now(self: *const Logger) i96 {
        if (self.now_fn) |f| return f();
        return std.Io.Clock.real.now(self.io).nanoseconds;
    }

    pub fn trace(self: *Logger, msg: []const u8, fields: anytype) void {
        self.emit(.trace, "", msg, fields);
    }
    pub fn debug(self: *Logger, msg: []const u8, fields: anytype) void {
        self.emit(.debug, "", msg, fields);
    }
    pub fn info(self: *Logger, msg: []const u8, fields: anytype) void {
        self.emit(.info, "", msg, fields);
    }
    pub fn warn(self: *Logger, msg: []const u8, fields: anytype) void {
        self.emit(.warn, "", msg, fields);
    }
    pub fn err(self: *Logger, msg: []const u8, fields: anytype) void {
        self.emit(.err, "", msg, fields);
    }

    pub fn scope(self: *Logger, name: []const u8) Bound(struct {}) {
        return .{ .logger = self, .scope_name = name, .fields = .{} };
    }

    pub fn with(self: *Logger, fields: anytype) Bound(@TypeOf(fields)) {
        return .{ .logger = self, .fields = fields };
    }
};

pub fn Bound(comptime F: type) type {
    return struct {
        const Self = @This();

        logger: ?*Logger = null,
        scope_name: []const u8 = "",
        fields: F,

        pub fn emit(self: Self, level: Level, msg: []const u8, extra: anytype) void {
            const lg = self.logger orelse getDefault() orelse return;
            lg.emit(level, self.scope_name, msg, encode.Pair(F, @TypeOf(extra)){ .a = self.fields, .b = extra });
        }

        pub fn trace(self: Self, msg: []const u8, extra: anytype) void {
            self.emit(.trace, msg, extra);
        }
        pub fn debug(self: Self, msg: []const u8, extra: anytype) void {
            self.emit(.debug, msg, extra);
        }
        pub fn info(self: Self, msg: []const u8, extra: anytype) void {
            self.emit(.info, msg, extra);
        }
        pub fn warn(self: Self, msg: []const u8, extra: anytype) void {
            self.emit(.warn, msg, extra);
        }
        pub fn err(self: Self, msg: []const u8, extra: anytype) void {
            self.emit(.err, msg, extra);
        }

        pub fn with(self: Self, extra: anytype) Bound(encode.Pair(F, @TypeOf(extra))) {
            return .{
                .logger = self.logger,
                .scope_name = self.scope_name,
                .fields = .{ .a = self.fields, .b = extra },
            };
        }

        pub fn scoped(self: Self, name: []const u8) Self {
            var copy = self;
            copy.scope_name = name;
            return copy;
        }
    };
}

var default_logger: std.atomic.Value(?*Logger) = .init(null);

/// The logger must outlive its use.
pub fn setDefault(logger: *Logger) void {
    default_logger.store(logger, .release);
}

pub fn clearDefault() void {
    default_logger.store(null, .release);
}

pub fn getDefault() ?*Logger {
    return default_logger.load(.acquire);
}

pub fn shouldColor(io: std.Io, file: std.Io.File, no_color_set: bool) bool {
    if (no_color_set) return false;
    return file.isTty(io) catch false;
}
