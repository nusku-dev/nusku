//! argv -> (resolved command, positional args, flag values).

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;
const Flag = command.Flag;
const FlagValues = command.FlagValues;
const ValueSource = command.ValueSource;

pub const Error = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidValue,
    MissingRequiredFlag,
    InvalidArgCount,
    OutOfMemory,
};

pub const Diagnostic = struct {
    message: []const u8 = "",
    command: ?*const Command = null,
    path: []const *const Command = &.{},
};

pub const EnvLookup = struct {
    context: ?*const anyopaque = null,
    getFn: *const fn (context: ?*const anyopaque, name: []const u8) ?[]const u8,

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        return self.getFn(self.context, name);
    }

    pub fn fromMap(map: *const std.process.Environ.Map) EnvLookup {
        const Adapter = struct {
            fn get(context: ?*const anyopaque, name: []const u8) ?[]const u8 {
                const m: *const std.process.Environ.Map = @ptrCast(@alignCast(context.?));
                return m.get(name);
            }
        };
        return .{ .context = map, .getFn = Adapter.get };
    }
};

pub const Options = struct {
    env: ?EnvLookup = null,
};

pub const Parsed = struct {
    command: *const Command,
    path: []const *const Command,
    args: []const []const u8,
    flags: FlagValues,
    help_requested: bool = false,
};

/// Slices inside the result point into `argv` and into `arena`, so both must outlive the result.
pub fn parse(
    arena: std.mem.Allocator,
    root: *const Command,
    argv: []const []const u8,
    opts: Options,
    diag: *Diagnostic,
) Error!Parsed {
    var st: State = .{ .arena = arena, .diag = diag };
    try st.path.append(arena, root);

    var positionals: std.ArrayList([]const u8) = .empty;
    var only_positional = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const tok = argv[i];

        if (only_positional or !isFlagLike(tok)) {
            if (!only_positional and positionals.items.len == 0) {
                const cur = st.current();
                if (cur.findSubcommand(tok)) |sub| {
                    try st.path.append(arena, sub);
                    continue;
                }
                if (cur.subcommands.len > 0 and cur.run == null) {
                    return st.fail(error.UnknownCommand, "unknown command \"{s}\" for \"{s}\"", .{ tok, cur.name });
                }
            }
            try positionals.append(arena, tok);
            continue;
        }

        if (std.mem.eql(u8, tok, "--")) {
            only_positional = true;
            continue;
        }

        if (std.mem.startsWith(u8, tok, "--")) {
            try st.parseLong(argv, &i);
        } else {
            try st.parseShort(argv, &i);
        }
    }

    const result_path = try st.path.toOwnedSlice(arena);
    const cmd = result_path[result_path.len - 1];
    const args = try positionals.toOwnedSlice(arena);

    if (st.help) {
        return .{ .command = cmd, .path = result_path, .args = args, .flags = st.flags, .help_requested = true };
    }

    st.path = .fromOwnedSlice(result_path);
    try st.applyDefaultsAndEnv(opts);

    if (!cmd.args.check(args.len)) {
        return st.fail(error.InvalidArgCount, "{s}: {s}", .{ cmd.name, try argsMessage(arena, cmd.args, args.len) });
    }

    return .{ .command = cmd, .path = result_path, .args = args, .flags = st.flags };
}

fn isFlagLike(tok: []const u8) bool {
    return tok.len >= 2 and tok[0] == '-';
}

fn argsMessage(arena: std.mem.Allocator, rule: command.ArgsRule, got: usize) std.mem.Allocator.Error![]const u8 {
    return switch (rule) {
        .any => unreachable,
        .none => std.fmt.allocPrint(arena, "takes no arguments, got {d}", .{got}),
        .exact => |k| std.fmt.allocPrint(arena, "expects exactly {d} argument(s), got {d}", .{ k, got }),
        .min => |k| std.fmt.allocPrint(arena, "expects at least {d} argument(s), got {d}", .{ k, got }),
        .max => |k| std.fmt.allocPrint(arena, "expects at most {d} argument(s), got {d}", .{ k, got }),
        .range => |r| std.fmt.allocPrint(arena, "expects {d} to {d} arguments, got {d}", .{ r.min, r.max, got }),
    };
}

const State = struct {
    arena: std.mem.Allocator,
    diag: *Diagnostic,
    path: std.ArrayList(*const Command) = .empty,
    flags: FlagValues = .{},
    help: bool = false,

    fn current(self: *const State) *const Command {
        return self.path.items[self.path.items.len - 1];
    }

    fn fail(self: *State, err: Error, comptime fmt: []const u8, args: anytype) Error {
        self.diag.message = std.fmt.allocPrint(self.arena, fmt, args) catch "";
        self.diag.command = self.current();
        self.diag.path = self.path.items;
        return err;
    }

    fn lookupLong(self: *const State, name: []const u8) ?*const Flag {
        var i = self.path.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.path.items[i];
            if (i == self.path.items.len - 1) {
                for (c.flags) |*f| if (std.mem.eql(u8, f.name, name)) return f;
            }
            for (c.persistent_flags) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    fn lookupShort(self: *const State, ch: u8) ?*const Flag {
        var i = self.path.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.path.items[i];
            if (i == self.path.items.len - 1) {
                for (c.flags) |*f| if (f.short == ch) return f;
            }
            for (c.persistent_flags) |*f| if (f.short == ch) return f;
        }
        return null;
    }

    fn validate(self: *State, flag: *const Flag, value: []const u8) Error!void {
        switch (flag.kind) {
            .string => {},
            .bool => if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
                return self.fail(error.InvalidValue, "invalid value \"{s}\" for --{s}: expected true or false", .{ value, flag.name });
            },
            .int => _ = std.fmt.parseInt(i64, value, 0) catch {
                return self.fail(error.InvalidValue, "invalid value \"{s}\" for --{s}: expected an integer", .{ value, flag.name });
            },
        }
    }

    fn set(self: *State, flag: *const Flag, value: []const u8, source: ValueSource) Error!void {
        try self.validate(flag, value);
        try self.flags.map.put(self.arena, flag.name, .{ .value = value, .source = source });
    }

    fn apply(self: *State, flag: *const Flag, inline_value: ?[]const u8, argv: []const []const u8, i: *usize) Error!void {
        if (inline_value) |v| return self.set(flag, v, .cli);
        if (flag.kind == .bool) return self.set(flag, "true", .cli);
        if (i.* + 1 >= argv.len) {
            return self.fail(error.MissingValue, "flag needs a value: --{s}", .{flag.name});
        }
        i.* += 1;
        return self.set(flag, argv[i.*], .cli);
    }

    fn parseLong(self: *State, argv: []const []const u8, i: *usize) Error!void {
        const body = argv[i.*][2..];
        var name = body;
        var inline_value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
            name = body[0..eq];
            inline_value = body[eq + 1 ..];
        }

        if (self.lookupLong(name)) |f| return self.apply(f, inline_value, argv, i);

        if (inline_value == null and std.mem.startsWith(u8, name, "no-")) {
            if (self.lookupLong(name[3..])) |f| {
                if (f.kind == .bool) return self.set(f, "false", .cli);
            }
        }

        if (inline_value == null and std.mem.eql(u8, name, "help")) {
            self.help = true;
            return;
        }

        return self.fail(error.UnknownFlag, "unknown flag: --{s}", .{name});
    }

    fn parseShort(self: *State, argv: []const []const u8, i: *usize) Error!void {
        const body = argv[i.*][1..];
        var k: usize = 0;
        while (k < body.len) : (k += 1) {
            const ch = body[k];
            const flag = self.lookupShort(ch) orelse {
                if (ch == 'h') {
                    self.help = true;
                    continue;
                }
                return self.fail(error.UnknownFlag, "unknown shorthand flag: -{c} in {s}", .{ ch, argv[i.*] });
            };

            if (flag.kind == .bool) {
                try self.set(flag, "true", .cli);
                continue;
            }

            const rest = body[k + 1 ..];
            if (rest.len > 0 and rest[0] == '=') return self.set(flag, rest[1..], .cli);
            if (rest.len > 0) return self.set(flag, rest, .cli);
            return self.apply(flag, null, argv, i);
        }
    }

    fn applyOne(self: *State, flag: *const Flag, opts: Options) Error!void {
        if (self.flags.map.contains(flag.name)) return;

        if (flag.env) |env_name| {
            if (opts.env) |env| {
                if (env.get(env_name)) |v| return self.set(flag, v, .env);
            }
        }

        if (flag.required) {
            return self.fail(error.MissingRequiredFlag, "required flag not set: --{s}", .{flag.name});
        }

        try self.set(flag, flag.defaultText(), .default);
    }

    fn applyDefaultsAndEnv(self: *State, opts: Options) Error!void {
        const cmd = self.current();
        for (cmd.flags) |*f| try self.applyOne(f, opts);
        var i = self.path.items.len;
        while (i > 0) {
            i -= 1;
            for (self.path.items[i].persistent_flags) |*f| try self.applyOne(f, opts);
        }
    }
};
