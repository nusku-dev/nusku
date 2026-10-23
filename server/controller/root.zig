//! The server's main component. It runs the agent, hands what the agent streams to the
//! symbolizer, and gives clients clean data.
const std = @import("std");
const symbolizer = @import("../symbolizer/root.zig");
const agent = @import("agent");
const function_totals = @import("../symbolizer/functions.zig");

const FunctionTotal = function_totals.FunctionTotal;
pub const StackLoss = agent.StackLoss;
/// Turns an agent report into the symbolizer's input. Only the arrays of structs are
/// allocated in `arena`; paths, build IDs and address slices still point into the report,
/// so the result must not outlive the report (inside the agent's callback is fine).
/// A report without a cpu part gives a window without stacks.
pub fn toWindow(arena: std.mem.Allocator, report: *const agent.Report) !symbolizer.Window {
    const regions = try arena.alloc(symbolizer.Region, report.regions.len);
    for (report.regions, regions) |src, *dst| {
        dst.* = .{
            .start = src.start,
            .end = src.end,
            .offset = src.offset,
            .path = src.path,
            .build_id = src.build_id,
            .inode = src.inode,
        };
    }

    const cpu_stacks: []const agent.StackSample = if (report.cpu) |cpu| cpu.stacks else &.{};
    const stacks = try arena.alloc(symbolizer.Stack, cpu_stacks.len);
    for (cpu_stacks, stacks) |src, *dst| {
        dst.* = .{
            .samples = src.samples,
            .user = src.user,
            .kernel = src.kernel,
            .leaf_is_return = src.leaf_is_return,
            .stop = src.stop,
        };
    }
    return .{
        .pid = report.pid,
        .regions = regions,
        .kernel = .{
            .release = report.kernel.release,
            .build_id = report.kernel.build_id,
            .text_address = report.kernel.text_address,
        },
        .stacks = stacks,
    };
}

/// What a client asks for.
pub const CpuOptions = struct {
    pid: u32,
    /// Milliseconds between reports.
    interval_ms: u32 = 1000,
    /// Seconds to run. 0 means until stopped.
    duration_s: u32 = 0,
    /// Lets another thread stop the run.
    cancel: ?*const agent.Cancel = null,
};

/// What a client receives, once per interval.
pub const CpuReport = struct {
    pid: u32,
    /// When the window began, as wall-clock nanoseconds since the Unix epoch.
    start_unix_ns: u64,
    duration_ns: u64,
    /// Samples per second on each CPU: `samples / sample_hz` is CPU seconds.
    sample_hz: u32,
    /// The sum of the samples over `stacks`.
    samples: u64,
    /// Most frequent first, frames root first.
    stacks: []const symbolizer.SymbolizedStack,
    /// Totals per function, the most expensive first: see `FunctionTotal`.
    functions: []const FunctionTotal = &.{},
    /// How long sampling was switched off to read the kernel's tables, in nanoseconds.
    /// Counts are low by about this share of the window.
    paused_ns: u64 = 0,
    /// Samples counted above whose stack is missing, and why.
    lost: StackLoss = .{},
};

pub const StopReason = agent.StopReason;

/// Profiles the CPU of one process and calls `onReport(context, *const CpuReport)` once per
/// interval, and once more for the last partial window. Blocks the calling thread, and the
/// callback runs on it. The report is only valid during the call. An error from the callback
/// stops the run and is returned. Needs root, or CAP_BPF and CAP_PERFMON.
pub fn profileCpu(
    allocator: std.mem.Allocator,
    options: CpuOptions,
    context: anytype,
    comptime onReport: anytype,
) !StopReason {
    const Adapter = struct {
        context: @TypeOf(context),
        allocator: std.mem.Allocator,
        sym: *symbolizer.Symbolizer,

        fn handle(self: *@This(), report: *const agent.Report) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const window = try toWindow(arena.allocator(), report);
            const raw = try self.sym.symbolize(arena.allocator(), window);
            const result = try symbolizer.merge(arena.allocator(), raw);
            const functions = try function_totals.summarize(arena.allocator(), result);

            const out = CpuReport{
                .pid = report.pid,
                .start_unix_ns = report.start_unix_ns,
                .duration_ns = report.duration_ns,
                .sample_hz = report.cpu_sample_hz,
                .samples = result.samples,
                .stacks = result.stacks,
                .functions = functions,
                .paused_ns = if (report.cpu) |cpu| cpu.paused_ns else 0,
                .lost = if (report.cpu) |cpu| cpu.lost else .{},
            };

            // The client's callback may return void or an error union.
            const Return = @typeInfo(@TypeOf(onReport)).@"fn".return_type.?;
            if (@typeInfo(Return) == .error_union) {
                try onReport(self.context, &out);
            } else {
                onReport(self.context, &out);
            }
        }
    };

    var sym = symbolizer.Symbolizer.init(allocator);
    defer sym.deinit();
    // The first report would otherwise pay for reading the kernel symbols, and that
    // delays the agent's next window.
    sym.preloadKernel();

    var adapter = Adapter{ .context = context, .allocator = allocator, .sym = &sym };

    return agent.profile(allocator, .{
        .pid = options.pid,
        .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
        .interval_ms = options.interval_ms,
        .duration_s = options.duration_s,
        .cancel = options.cancel,
    }, &adapter, Adapter.handle);
}

// ------------------------------------------------------------------ tests

fn sampleReport(stacks: []agent.StackSample, regions: []const agent.Region) agent.Report {
    return .{
        .start_unix_ns = 1,
        .duration_ns = 2,
        .pid = 42,
        .cpu_sample_hz = 99,
        .regions = regions,
        .kernel = .{ .release = "6.8.0-test", .build_id = null, .text_address = 0xffffffff81000000 },
        .cpu = .{ .samples = 4, .stacks = stacks },
    };
}

test "toWindow copies the regions, the kernel identity and the stacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const regions = [_]agent.Region{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0x500, .inode = 7, .path = "/bin/app", .build_id = null },
    };
    var stacks = [_]agent.StackSample{
        .{ .samples = 4, .user = &.{ 0x1010, 0x1020 }, .kernel = &.{0xffff0001}, .leaf_is_return = true },
    };
    const report = sampleReport(&stacks, &regions);

    const window = try toWindow(arena.allocator(), &report);

    try std.testing.expectEqual(@as(u64, 7), window.regions[0].inode);
    try std.testing.expectEqual(@as(u32, 42), window.pid);
    try std.testing.expectEqual(@as(usize, 1), window.regions.len);
    try std.testing.expectEqual(@as(u64, 0x1000), window.regions[0].start);
    try std.testing.expectEqual(@as(u64, 0x2000), window.regions[0].end);
    try std.testing.expectEqual(@as(u64, 0x500), window.regions[0].offset);
    try std.testing.expectEqualStrings("/bin/app", window.regions[0].path);
    try std.testing.expect(window.regions[0].build_id == null);

    try std.testing.expectEqualStrings("6.8.0-test", window.kernel.release);
    try std.testing.expectEqual(@as(?u64, 0xffffffff81000000), window.kernel.text_address);

    try std.testing.expectEqual(@as(usize, 1), window.stacks.len);
    try std.testing.expectEqual(@as(u64, 4), window.stacks[0].samples);
    try std.testing.expectEqual(@as(usize, 2), window.stacks[0].user.len);
    try std.testing.expectEqual(@as(u64, 0x1020), window.stacks[0].user[1]);
    try std.testing.expectEqual(@as(?bool, true), window.stacks[0].leaf_is_return);
    try std.testing.expectEqual(@as(u64, 0xffff0001), window.stacks[0].kernel[0]);
}

test "a report without a cpu part gives a window without stacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var report = sampleReport(&.{}, &.{});
    report.cpu = null;

    const window = try toWindow(arena.allocator(), &report);
    try std.testing.expectEqual(@as(usize, 0), window.stacks.len);
    try std.testing.expectEqual(@as(usize, 0), window.regions.len);
}

test "a converted report flows through the symbolizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var sym = symbolizer.Symbolizer.init(std.testing.allocator);
    defer sym.deinit();

    const regions = [_]agent.Region{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0, .inode = 7, .path = "/bin/app", .build_id = null },
    };
    var stacks = [_]agent.StackSample{
        .{ .samples = 4, .user = &.{ 0x1010, 0x1020 }, .kernel = &.{} },
    };
    const report = sampleReport(&stacks, &regions);

    const window = try toWindow(arena.allocator(), &report);
    const result = try sym.symbolize(arena.allocator(), window);

    try std.testing.expectEqual(@as(u64, 4), result.samples);
    try std.testing.expectEqual(@as(usize, 2), result.stacks[0].frames.len);
    try std.testing.expectEqual(@as(u64, 0x1020), result.stacks[0].frames[0].address); // root first
    try std.testing.expectEqualStrings("/bin/app", result.stacks[0].frames[1].module.?);
}

const Seen = struct {
    reports: usize = 0,
    samples: u64 = 0,
    pid: u32 = 0,
    frames: usize = 0,
    with_module: usize = 0,
    functions: usize = 0,
    inconsistent: usize = 0,
    paused_ns: u64 = 0,
    /// Samples that landed in a function whose name contains "burn".
    burn_self: u64 = 0,

    fn onReport(self: *Seen, report: *const CpuReport) void {
        self.reports += 1;
        self.samples += report.samples;
        self.pid = report.pid;
        self.functions += report.functions.len;
        self.paused_ns += report.paused_ns;
        if (self.reports == 1) {
            for (report.functions[0..@min(report.functions.len, 3)]) |function| {
                std.debug.print("  top function: {s} self {d} total {d} of {d}\n", .{ function.name orelse "(no name)", function.self, function.total, report.samples });
            }
        }
        for (report.functions) |function| {
            if (function.total < function.self or function.total > report.samples) self.inconsistent += 1;
            if (function.name) |name| {
                if (std.mem.indexOf(u8, name, "burn") != null) self.burn_self += function.self;
            }
        }
        for (report.stacks) |stack| {
            for (stack.frames) |frame| {
                self.frames += 1;
                if (frame.module != null) self.with_module += 1;
            }
        }
    }
};

fn burn(stop: *std.atomic.Value(bool)) void {
    var x: u64 = 0;
    while (!stop.load(.acquire)) x +%= 1;
    std.mem.doNotOptimizeAway(x);
}

test "profileCpu rejects an invalid pid before doing anything" {
    var seen = Seen{};
    try std.testing.expectError(
        error.InvalidPid,
        profileCpu(std.testing.allocator, .{ .pid = 0 }, &seen, Seen.onReport),
    );
    try std.testing.expectEqual(@as(usize, 0), seen.reports);
}

test "profileCpu streams symbolized reports for a process (needs root, skipped otherwise)" {
    // A second thread burns CPU inside our own process, which is the one we profile.
    var stop = std.atomic.Value(bool).init(false);
    const burner = try std.Thread.spawn(.{}, burn, .{&stop});
    defer burner.join();
    defer stop.store(true, .release);

    const me: u32 = @intCast(std.os.linux.getpid());
    var seen = Seen{};
    const reason = profileCpu(std.testing.allocator, .{
        .pid = me,
        .interval_ms = 300,
        .duration_s = 1,
    }, &seen, Seen.onReport) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    std.debug.print("controller: {d} of {d} samples were in burn\n", .{ seen.burn_self, seen.samples });
    try std.testing.expectEqual(StopReason.duration, reason);
    try std.testing.expect(seen.reports >= 3 and seen.reports <= 5);
    try std.testing.expect(seen.samples >= 20);
    try std.testing.expectEqual(me, seen.pid);
    try std.testing.expect(seen.frames == 0 or seen.with_module > 0);
    try std.testing.expect(seen.functions > 0);
    try std.testing.expectEqual(@as(usize, 0), seen.inconsistent);
    // One thread spends all its time in `burn`, so almost every sample must name it.
    try std.testing.expect(seen.burn_self * 10 >= seen.samples * 8);
}
