//! The control layer: the local client.

const std = @import("std");
const assert = std.debug.assert;
const agent = @import("agent");
const protocol = @import("shared").protocol;
const server_layer = @import("../server/server.zig");
const job_file = @import("job.zig");
const log = @import("../log.zig").server;

const Server = server_layer.Server;
const Job = job_file.Job;

pub const JobId = job_file.JobId;
pub const Done = job_file.Done;

pub const Spec = union(enum) {
    profile: Profile,
    processes: Processes,

    pub const Profile = struct {
        pid: ?u32 = null,
        program: ?protocol.Program = null,
        metrics: std.EnumSet(protocol.Metric) = .initOne(.cpu),
        interval_ms: u32 = 1000,
        duration_s: u32 = 0,
    };

    pub const Processes = struct {
        interval_ms: u32 = 1000,
        duration_s: u32 = 0,
    };
};

pub const Started = struct {
    job: JobId,
    pid: ?u32 = null,
    target: ?server_layer.TargetId,
};

pub const Options = struct {
    jobs_max: u32 = 16,
};

const children_max = 64;

pub const Controller = struct {
    gpa: std.mem.Allocator,
    server: *Server,
    jobs: []Job,
    next_id: JobId,
    children: std.ArrayList(u32),

    pub fn init(
        controller: *Controller,
        gpa: std.mem.Allocator,
        server: *Server,
        options: Options,
    ) !void {
        assert(options.jobs_max > 0);
        const jobs = try gpa.alloc(Job, options.jobs_max);
        for (jobs) |*job| job.active = false;
        controller.* = .{
            .gpa = gpa,
            .server = server,
            .jobs = jobs,
            .next_id = 1,
            .children = .empty,
        };
    }

    pub fn deinit(controller: *Controller) void {
        controller.interrupt();
        for (controller.jobs) |*job| {
            if (job.active) _ = controller.finish(job) catch {};
        }
        controller.children_reap();
        controller.children.deinit(controller.gpa);
        controller.gpa.free(controller.jobs);
        controller.* = undefined;
    }

    pub fn start(controller: *Controller, spec: Spec) !Started {
        const kind = std.meta.activeTag(spec);
        errdefer |err| log.err("job not started", .{ .kind = kind, .cause = err });
        controller.children_reap();
        const job = controller.free() orelse return error.JobsFull;
        job.* = .{
            .id = controller.next_id,
            .active = false,
            .thread = undefined,
            .work = undefined,
            .result = error.NotFinished,
            .finished = .init(false),
        };
        var target: ?server_layer.TargetId = null;
        var pid: ?u32 = null;
        switch (spec) {
            .profile => |profile| {
                job.work = .{ .profile = .{
                    .run = try agent.Run.init(controller.gpa, .{
                        .pid = profile.pid,
                        .program = profile.program,
                        .metrics = profile.metrics,
                        .interval_ms = profile.interval_ms,
                        .duration_s = profile.duration_s,
                    }),
                    .feed = undefined,
                } };
                const run = &job.work.profile.run;
                errdefer run.deinit();
                const launched = profile.program != null;
                if (launched) try controller.children.ensureUnusedCapacity(controller.gpa, 1);
                job.work.profile.feed = try controller.server.feed(run.pid);
                target = job.work.profile.feed.target;
                pid = run.pid;
                if (launched) controller.children.appendAssumeCapacity(run.pid);
            },
            .processes => |processes| {
                if (controller.watching()) return error.AlreadyWatching;
                job.work = .{ .processes = try agent.Watch.init(controller.gpa, .{
                    .interval_ms = processes.interval_ms,
                    .duration_s = processes.duration_s,
                }) };
            },
        }
        errdefer job.deinit();
        job.thread = try std.Thread.spawn(.{}, Job.thread_main, .{ job, controller.server });
        job.active = true;
        controller.next_id += 1;
        log.info("job started", .{ .job = job.id, .kind = std.meta.activeTag(spec) });
        return .{ .job = job.id, .pid = pid, .target = target };
    }

    pub fn stop(controller: *Controller, id: JobId) !Done {
        const job = controller.find(id) orelse return error.JobUnknown;
        job.stop();
        return controller.finish(job);
    }

    pub fn wait(controller: *Controller, id: JobId) !Done {
        const job = controller.find(id) orelse return error.JobUnknown;
        return controller.finish(job);
    }

    pub fn running(controller: *Controller, id: JobId) bool {
        controller.children_reap();
        const job = controller.find(id) orelse return false;
        return !job.finished.load(.acquire);
    }

    /// Safe from a signal handler.
    pub fn interrupt(controller: *const Controller) void {
        for (controller.jobs) |*job| {
            if (job.active) job.stop();
        }
    }

    fn finish(controller: *Controller, job: *Job) !Done {
        _ = controller;
        assert(job.active);
        job.thread.join();
        const result = job.result;
        job.deinit();
        if (result) |done| switch (done) {
            .profile => |reason| log.info("job ended", .{
                .job = job.id,
                .kind = "profile",
                .reason = reason,
            }),
            .processes => |reason| log.info("job ended", .{
                .job = job.id,
                .kind = "processes",
                .reason = reason,
            }),
        } else |err| {
            log.err("job failed", .{ .job = job.id, .cause = err });
        }
        return result;
    }

    fn children_reap(controller: *Controller) void {
        var index: usize = 0;
        while (index < controller.children.items.len) {
            if (agent.program_reaped(controller.children.items[index])) {
                _ = controller.children.swapRemove(index);
            } else {
                index += 1;
            }
        }
        if (controller.children.items.len > children_max) {
            log.warn("launched programs not reaped yet", .{
                .count = controller.children.items.len,
            });
        }
    }
    fn free(controller: *Controller) ?*Job {
        for (controller.jobs) |*job| {
            if (!job.active) return job;
        }
        return null;
    }

    fn find(controller: *Controller, id: JobId) ?*Job {
        for (controller.jobs) |*job| {
            if (job.active and job.id == id) return job;
        }
        return null;
    }

    fn watching(controller: *const Controller) bool {
        for (controller.jobs) |*job| {
            if (job.active and job.work == .processes) return true;
        }
        return false;
    }
};

const testing = std.testing;
const burn = @import("../testing/burn.zig").burn;

const Fixture = struct {
    server: Server,
    controller: Controller,

    fn create() !*Fixture {
        const fixture = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(fixture);
        try fixture.server.init(testing.allocator, .{ .windows = .{
            .targets_max = 1,
            .windows_per_target_max = 16,
            .window_bytes_max = 256 * 1024,
        } });
        errdefer fixture.server.deinit();
        try fixture.controller.init(testing.allocator, &fixture.server, .{ .jobs_max = 2 });
        return fixture;
    }

    fn destroy(fixture: *Fixture) void {
        fixture.controller.deinit();
        fixture.server.deinit();
        testing.allocator.destroy(fixture);
    }

    fn samples(fixture: *Fixture, target: server_layer.TargetId) !u64 {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const query = server_layer.Query{ .target = target };
        return (try fixture.server.profile(arena.allocator(), query, .as_they_are)).samples;
    }
};

test "a bad spec and an unknown job are refused before anything starts" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const controller = &fixture.controller;

    try testing.expectError(error.InvalidPid, controller.start(.{ .profile = .{ .pid = 0 } }));
    const no_interval = Spec{ .profile = .{ .pid = 1, .interval_ms = 0 } };
    try testing.expectError(error.InvalidInterval, controller.start(no_interval));
    const no_metrics = Spec{ .profile = .{ .pid = 1, .metrics = .initEmpty() } };
    try testing.expectError(error.NoMetrics, controller.start(no_metrics));
    try testing.expectError(error.NoTarget, controller.start(.{ .profile = .{} }));
    const missing = Spec{ .profile = .{ .program = .{ .argv = &.{"no-such-program-nusku"} } } };
    try testing.expectError(error.ProgramNotFound, controller.start(missing));
    try testing.expectError(error.JobUnknown, controller.stop(42));
    try testing.expect(!controller.running(42));
}

test "a profile of this process feeds the server until it is stopped (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const pid: u32 = @intCast(std.os.linux.getpid());
    const spec = Spec{ .profile = .{ .pid = pid, .interval_ms = 100 } };
    const started = try fixture.controller.start(spec);
    try testing.expect(fixture.controller.running(started.job));
    var waited: u32 = 0;
    while (try fixture.samples(started.target.?) < 10) : (waited += 1) {
        if (waited > 200) return error.NoSamples;
        burn(50);
    }
    const done = try fixture.controller.stop(started.job);
    try testing.expectEqual(Done{ .profile = .cancelled }, done);
    try testing.expect(!fixture.controller.running(started.job));
    std.debug.print("controller: {d} samples\n", .{try fixture.samples(started.target.?)});
}

test "a launched program feeds the server under its pid, and is reaped once it ends (root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const controller = &fixture.controller;

    const busy = [_][]const u8{ "sh", "-c", "while :; do :; done" };
    const spec = Spec{ .profile = .{ .program = .{ .argv = &busy }, .interval_ms = 100 } };
    const started = try controller.start(spec);
    const pid = started.pid.?;
    try testing.expect(alive(pid));
    var waited: u32 = 0;
    while (try fixture.samples(started.target.?) < 10) : (waited += 1) {
        if (waited > 200) return error.NoSamples;
        burn(50);
    }
    try testing.expectEqual(Done{ .profile = .cancelled }, try controller.stop(started.job));
    waited = 0;
    while (alive(pid)) : (waited += 1) {
        if (waited > 200) return error.NotReaped;
        burn(10);
        _ = controller.running(started.job);
    }
    try testing.expectEqual(@as(usize, 0), controller.children.items.len);
}

fn alive(pid: u32) bool {
    return std.os.linux.errno(std.os.linux.kill(@intCast(pid), @enumFromInt(0))) == .SUCCESS;
}

test "the processes watch starts, refuses a second, and stops when asked" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const controller = &fixture.controller;
    const server = &fixture.server;

    const started = try controller.start(.{ .processes = .{ .interval_ms = 100 } });
    try testing.expectEqual(@as(?server_layer.TargetId, null), started.target);
    try testing.expect(controller.running(started.job));
    const second = controller.start(.{ .processes = .{ .interval_ms = 100 } });
    try testing.expectError(error.AlreadyWatching, second);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var latest = try server.processes(arena.allocator());
    var waited: u32 = 0;
    while (latest.frames < 2) : (waited += 1) {
        if (waited > 100) return error.NoFrames;
        burn(50);
        latest = try server.processes(arena.allocator());
    }
    const own: u32 = @intCast(std.os.linux.getpid());
    const found = for (latest.frame.?.processes) |info| {
        if (info.pid == own) break true;
    } else false;
    try testing.expect(found);

    try testing.expectEqual(Done{ .processes = .cancelled }, try controller.stop(started.job));
    try testing.expect(!controller.running(started.job));
}
