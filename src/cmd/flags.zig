//! Flags that more than one command reads.

const std = @import("std");
const cli = @import("cli");
const log = @import("log");

pub fn log_apply(ctx: *cli.Context) error{InvalidUsage}!void {
    const logger = log.getDefault() orelse return;
    if (ctx.getBool("verbose")) logger.setLevel(.debug);

    if (ctx.isSet("log-level")) {
        const text = ctx.getString("log-level");
        const level = log.Level.parse(text) orelse return ctx.usageFail(
            "unknown --log-level \"{s}\" (trace, debug, info, warn, error, off)",
            .{text},
        );
        logger.setLevel(level);
    }
    if (ctx.isSet("log-format")) {
        const text = ctx.getString("log-format");
        const format = std.meta.stringToEnum(log.Format, text) orelse return ctx.usageFail(
            "unknown --log-format \"{s}\" (text, logfmt, json)",
            .{text},
        );
        logger.setFormat(format);
    }
}

pub const color: cli.Flag = .{
    .name = "color",
    .kind = .string,
    .default = "auto",
    .help = "auto (when the output is a terminal and NO_COLOR is unset), always, never",
};

pub fn color_read(ctx: *cli.Context) error{InvalidUsage}!bool {
    const text = ctx.getString("color");
    if (std.mem.eql(u8, text, "always")) return true;
    if (std.mem.eql(u8, text, "never")) return false;
    if (!std.mem.eql(u8, text, "auto")) {
        return ctx.usageFail("--color must be auto, always or never (got \"{s}\")", .{text});
    }
    const no_color = std.c.getenv("NO_COLOR") != null;
    return log.shouldColor(ctx.io, std.Io.File.stdout(), no_color);
}
