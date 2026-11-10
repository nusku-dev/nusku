//! Command tree, flag definitions, and the Context handed to `run`.

const std = @import("std");
const errors = @import("errors.zig");

pub const FlagKind = enum { bool, string, int };

pub const Flag = struct {
    name: []const u8,
    short: ?u8 = null,
    kind: FlagKind = .string,
    help: []const u8 = "",
    default: ?[]const u8 = null,
    env: ?[]const u8 = null,
    required: bool = false,

    pub fn defaultText(self: Flag) []const u8 {
        if (self.default) |d| return d;
        return switch (self.kind) {
            .bool => "false",
            .string => "",
            .int => "0",
        };
    }
};

pub const ArgsRule = union(enum) {
    any,
    none,
    exact: usize,
    min: usize,
    max: usize,
    range: struct { min: usize, max: usize },

    pub fn check(self: ArgsRule, n: usize) bool {
        return switch (self) {
            .any => true,
            .none => n == 0,
            .exact => |k| n == k,
            .min => |k| n >= k,
            .max => |k| n <= k,
            .range => |r| n >= r.min and n <= r.max,
        };
    }
};

pub const RunFn = *const fn (ctx: *Context) anyerror!void;

pub const Command = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    short: []const u8 = "",
    long: ?[]const u8 = null,
    usage_args: []const u8 = "",
    flags: []const Flag = &.{},
    persistent_flags: []const Flag = &.{},
    subcommands: []const *const Command = &.{},
    args: ArgsRule = .any,
    hidden: bool = false,
    run: ?RunFn = null,

    pub fn matches(self: *const Command, word: []const u8) bool {
        if (std.mem.eql(u8, self.name, word)) return true;
        for (self.aliases) |a| if (std.mem.eql(u8, a, word)) return true;
        return false;
    }

    pub fn findSubcommand(self: *const Command, word: []const u8) ?*const Command {
        for (self.subcommands) |sub| if (sub.matches(word)) return sub;
        return null;
    }
};

pub const ValueSource = enum { default, env, cli };

pub const FlagValues = struct {
    pub const Entry = struct {
        value: []const u8,
        source: ValueSource,
    };

    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn get(self: *const FlagValues, name: []const u8) ?Entry {
        return self.map.get(name);
    }

    fn must(self: *const FlagValues, name: []const u8) Entry {
        return self.map.get(name) orelse
            std.debug.panic("cli: flag --{s} is not defined for this command", .{name});
    }

    pub fn isSet(self: *const FlagValues, name: []const u8) bool {
        return self.must(name).source != .default;
    }

    pub fn getBool(self: *const FlagValues, name: []const u8) bool {
        return std.mem.eql(u8, self.must(name).value, "true");
    }

    pub fn getString(self: *const FlagValues, name: []const u8) []const u8 {
        return self.must(name).value;
    }

    pub fn getInt(self: *const FlagValues, name: []const u8) i64 {
        const v = self.must(name).value;
        return std.fmt.parseInt(i64, v, 0) catch
            std.debug.panic("cli: flag --{s} holds non-integer default \"{s}\"", .{ name, v });
    }
};

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    prog: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    command: *const Command,
    args: []const []const u8,
    flags: *const FlagValues,

    pub fn fail(self: *const Context, comptime fmt: []const u8, args: anytype) error{Reported} {
        self.stderr.print("{s}: " ++ fmt ++ "\n", .{self.prog} ++ args) catch {};
        return error.Reported;
    }

    pub fn usageFail(self: *const Context, comptime fmt: []const u8, args: anytype) error{InvalidUsage} {
        self.stderr.print("{s}: " ++ fmt ++ "\n", .{self.prog} ++ args) catch {};
        return error.InvalidUsage;
    }

    pub fn getBool(self: *const Context, name: []const u8) bool {
        return self.flags.getBool(name);
    }
    pub fn getString(self: *const Context, name: []const u8) []const u8 {
        return self.flags.getString(name);
    }
    pub fn getInt(self: *const Context, name: []const u8) i64 {
        return self.flags.getInt(name);
    }
    pub fn isSet(self: *const Context, name: []const u8) bool {
        return self.flags.isSet(name);
    }
};
