//! Help and usage rendering.

const std = @import("std");
const command = @import("command.zig");
const Command = command.Command;
const Flag = command.Flag;

const Writer = std.Io.Writer;
pub const Error = Writer.Error;

const help_flag: Flag = .{ .name = "help", .short = 'h', .kind = .bool, .help = "Show help for this command" };

const Section = enum { local, inherited };

pub fn writePath(w: *Writer, path: []const *const Command) Error!void {
    for (path, 0..) |c, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(c.name);
    }
}

pub fn writeUsageHint(w: *Writer, path: []const *const Command) Error!void {
    try w.writeAll("Run '");
    try writePath(w, path);
    try w.writeAll(" --help' for usage.\n");
}

pub fn writeHelp(w: *Writer, path: []const *const Command) Error!void {
    const cmd = path[path.len - 1];

    const intro: []const u8 = cmd.long orelse cmd.short;
    if (intro.len > 0) try w.print("{s}\n\n", .{intro});

    try w.writeAll("Usage:\n");
    const has_subs = visibleSubcommands(cmd) > 0;
    if (cmd.run != null or !has_subs) {
        try w.writeAll("  ");
        try writePath(w, path);
        try w.writeAll(" [flags]");
        if (cmd.usage_args.len > 0) try w.print(" {s}", .{cmd.usage_args});
        try w.writeByte('\n');
    }
    if (has_subs) {
        try w.writeAll("  ");
        try writePath(w, path);
        try w.writeAll(" [command]\n");
    }

    if (cmd.aliases.len > 0 and path.len > 1) {
        try w.writeAll("\nAliases:\n  ");
        try w.writeAll(cmd.name);
        for (cmd.aliases) |a| try w.print(", {s}", .{a});
        try w.writeByte('\n');
    }

    if (has_subs) {
        var width: usize = 0;
        for (cmd.subcommands) |sub| {
            if (!sub.hidden) width = @max(width, sub.name.len);
        }
        try w.writeAll("\nCommands:\n");
        for (cmd.subcommands) |sub| {
            if (sub.hidden) continue;
            try w.print("  {s}", .{sub.name});
            try w.splatByteAll(' ', width - sub.name.len + 3);
            try w.print("{s}\n", .{sub.short});
        }
    }

    try writeFlagSection(w, path, .local, "Flags");
    try writeFlagSection(w, path, .inherited, "Global Flags");

    if (has_subs) {
        try w.writeAll("\nUse \"");
        try writePath(w, path);
        try w.writeAll(" [command] --help\" for more information about a command.\n");
    }
}

fn visibleSubcommands(cmd: *const Command) usize {
    var n: usize = 0;
    for (cmd.subcommands) |sub| {
        if (!sub.hidden) n += 1;
    }
    return n;
}

fn visit(path: []const *const Command, section: Section, visitor: anytype) Error!void {
    const cmd = path[path.len - 1];
    switch (section) {
        .local => {
            if (!definesHelp(path)) try visitor.flag(&help_flag);
            for (cmd.flags) |*f| try visitor.flag(f);
            for (cmd.persistent_flags) |*f| try visitor.flag(f);
        },
        .inherited => {
            for (path[0 .. path.len - 1]) |c| {
                for (c.persistent_flags) |*f| try visitor.flag(f);
            }
        },
    }
}

fn definesHelp(path: []const *const Command) bool {
    const cmd = path[path.len - 1];
    for (cmd.flags) |f| if (std.mem.eql(u8, f.name, "help")) return true;
    for (path) |c| {
        for (c.persistent_flags) |f| if (std.mem.eql(u8, f.name, "help")) return true;
    }
    return false;
}

const Measure = struct {
    count: usize = 0,
    width: usize = 0,

    fn flag(self: *Measure, f: *const Flag) Error!void {
        self.count += 1;
        self.width = @max(self.width, labelLen(f.*));
    }
};

const Print = struct {
    w: *Writer,
    width: usize,

    fn flag(self: *Print, f: *const Flag) Error!void {
        const w = self.w;
        try w.writeAll("  ");
        if (f.short) |s| try w.print("-{c}, ", .{s}) else try w.writeAll("    ");
        try w.print("--{s}", .{f.name});
        if (typeWord(f.kind)) |t| try w.print(" {s}", .{t});
        try w.splatByteAll(' ', self.width - labelLen(f.*) + 3);

        var wrote_any = false;
        if (f.help.len > 0) {
            try w.writeAll(f.help);
            wrote_any = true;
        }
        if (f.default) |d| {
            if (wrote_any) try w.writeByte(' ');
            switch (f.kind) {
                .string => try w.print("(default \"{s}\")", .{d}),
                else => try w.print("(default {s})", .{d}),
            }
            wrote_any = true;
        }
        if (f.env) |e| {
            if (wrote_any) try w.writeByte(' ');
            try w.print("[env: {s}]", .{e});
            wrote_any = true;
        }
        if (f.required) {
            if (wrote_any) try w.writeByte(' ');
            try w.writeAll("(required)");
        }
        try w.writeByte('\n');
    }
};

fn typeWord(kind: command.FlagKind) ?[]const u8 {
    return switch (kind) {
        .bool => null,
        .string => "string",
        .int => "int",
    };
}

fn labelLen(f: Flag) usize {
    const type_len = if (typeWord(f.kind)) |t| t.len + 1 else 0;
    return 2 + 4 + 2 + f.name.len + type_len;
}

fn writeFlagSection(w: *Writer, path: []const *const Command, section: Section, title: []const u8) Error!void {
    var m: Measure = .{};
    try visit(path, section, &m);
    if (m.count == 0) return;

    try w.print("\n{s}:\n", .{title});
    var p: Print = .{ .w = w, .width = m.width };
    try visit(path, section, &p);
}
