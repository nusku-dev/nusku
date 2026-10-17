const std = @import("std");
const log = @import("log");
const cli = @import("cli");
const utils = @import("_utils.zig");
const Metric = @import("agent").Metric;
const ag = @import("../clients/agent.zig");
const slog = log.scope("prof");

const Agent = ag.Agent;

pub const cmd: cli.Command = .{
    .name = "prof",
    .short = "Profile a running process or launch one to profile",
    .long =
    \\Profile a Linux process and collect detailed runtime performance data.
    \\
    \\You can attach to an existing process with --pid, or launch a new
    \\process with --executable. When launching a process, arguments after
    \\the executable path are passed directly to it.
    ,
    .flags = &.{
        .{
            .name = "exec",
            .short = 'e',
            .kind = .string,
            .help = "Path to the executable to launch and profile",
        },
        .{
            .name = "pid",
            .short = 'p',
            .kind = .int,
            .help = "PID of an already running process to profile",
        },
        .{
            .name = "metrics",
            .kind = .string,
            .default = "cpu",
            //  .default = "cpu,offcpu,mem,io,net,locks,sched",
            .help = "Comma-separated list of metrics to collect",
        },
        .{
            .name = "interval",
            .kind = .int,
            .default = "1000",
            .help = "Sampling interval in milliseconds",
        },
        .{
            .name = "duration",
            .kind = .int,
            .default = "0",
            .help = "How long to profile in seconds; 0 means run until stopped",
        },
    },
    .usage_args = "[args...]",
    .args = .any,
    .run = run,
};

fn run(ctx: *cli.Context) anyerror!void {
    try utils.logConfig(ctx);

    const has_exec = ctx.isSet("exec");
    const has_pid = ctx.isSet("pid");

    slog.debug("starting prof command", .{
        .exec = has_exec,
        .pid = has_pid,
    });
    if (!has_exec and !has_pid) return ctx.usageFail("one of --exec or --pid is required", .{});
    if (has_exec and has_pid) return ctx.usageFail("--exec and --pid cannot be used together", .{});
    if (has_pid and ctx.args.len > 0) return ctx.usageFail("arguments after -- only apply to --exec", .{});

    const pid = ctx.getInt("pid");
    if (has_pid and pid <= 0) return ctx.usageFail("--pid must be a positive number (got {d})", .{pid});

    const interval = ctx.getInt("interval");
    if (interval < 10) return ctx.usageFail("--interval must be at least 10 ms (got {d})", .{interval});

    const duration = ctx.getInt("duration");
    if (duration < 0) return ctx.usageFail("--duration cannot be negative (got {d})", .{duration});

    const metrics = try parseMetrics(ctx);

    slog.debug("profiling configuration validated", .{
        .interval_ms = interval,
        .duration_s = duration,
        .metrics = ctx.getString("metrics"),
    });

    var agent = Agent{
        .pid = null,
        .io = ctx.io,
        .interval = interval,
        .duration = duration,
        .metrics = metrics,
    };

    if (has_exec) {
        try agent.initExec(ctx.allocator, ctx.getString("exec"), ctx.args);
    } else {
        agent.pid = @intCast(pid);
    }

    slog.debug("starting agent", .{
        .pid = agent.pid.?,
    });

    agent.run(ctx.allocator, ctx.stdout) catch |err| {
        slog.err("agent failed to start", .{
            .pid = agent.pid,
            .cause = err,
        });
        return err;
    };

    slog.info("profiler started", .{
        .pid = agent.pid.?,
        .interval_ms = agent.interval,
        .duration_s = agent.duration,
        .metrics = ctx.getString("metrics"),
    });
}

fn parseMetrics(ctx: *cli.Context) error{InvalidUsage}!std.EnumSet(Metric) {
    var set: std.EnumSet(Metric) = .initEmpty();
    var parts = std.mem.splitScalar(u8, ctx.getString("metrics"), ',');
    while (parts.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        const metric = std.meta.stringToEnum(Metric, name) orelse
            return ctx.usageFail("unknown metric \"{s}\" (valid: cpu, offcpu, mem, io, net, locks, sched)", .{name});
        set.insert(metric);
    }
    return set;
}
