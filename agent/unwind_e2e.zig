//! The BPF unwinder against userspace, on a real process (this test process). Each test loads
//! the tables of the process into the kernel, samples it while it spins, and compares what the
//! BPF program computed with what the userspace code computes from the same inputs.
const std = @import("std");
const ebpf = @import("ebpf");
const unwind = @import("unwind");
const procmaps = @import("core/procmaps.zig");
const tables = @import("core/tables.zig");
const sys = @import("core/sys.zig");

const testing = std.testing;

noinline fn spin(iterations: u64, marker: *u8) u64 {
    var x: u64 = 1;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        x = x *% 6364136223846793005 +% 1;
        marker.* = @truncate(x);
    }
    return x;
}

/// A loop of cheap system calls, so that most samples land in kernel mode.
noinline fn syscallSpin(iterations: u64) u64 {
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        x +%= @as(u64, @intCast(std.os.linux.getppid()));
    }
    return x;
}

const Workload = enum { spin, syscalls, faults, anon_chain, anon_zero, anon_unaligned, anon_below, anon_outside, anon_invalid };
const KernelShare = enum { dont_care, syscalls, faults };

/// One region for the whole fault workload: each call touches the next 64 MiB of it, so every
/// call faults in fresh pages and no system call runs while it is being sampled.
var fault_region: ?[]u8 = null;
var fault_offset: usize = 0;
const fault_chunk = 64 * 1024 * 1024;
const fault_total = 16 * fault_chunk;

noinline fn faultSpin() u64 {
    if (fault_region == null) {
        fault_region = sys.reserve(fault_total) catch return 0;
        fault_offset = 0;
    }
    const region = fault_region.?;
    if (fault_offset + fault_chunk > region.len) return 0;
    var x: u64 = 0;
    var offset: usize = fault_offset;
    const end = offset + fault_chunk;
    while (offset < end) : (offset += 4096) {
        region[offset] = 1;
        x +%= offset;
    }
    fault_offset = end;
    return x;
}

fn releaseFaults() void {
    if (fault_region) |region| sys.release(region);
    fault_region = null;
}

extern "c" fn mprotect(addr: *anyopaque, len: usize, prot: c_int) c_int;

var anon_region: ?[]u8 = null;

fn isAnon(w: Workload) bool {
    return switch (w) {
        .anon_chain, .anon_zero, .anon_unaligned, .anon_below, .anon_outside, .anon_invalid => true,
        else => false,
    };
}

fn emit(buf: []u8, at: *usize, bytes: []const u8) void {
    @memcpy(buf[at.*..][0..bytes.len], bytes);
    at.* += bytes.len;
}

/// Machine code in an anonymous executable page, like a JIT would produce: it has no unwind
/// tables, so the walk has to leave its frame through the frame pointer. Every variant starts
/// with `push rbp`, sets rbp to something, spins in a counting loop, and puts everything back.
fn makeAnon(w: Workload) !void {
    const region = try sys.reserve(4096);
    errdefer sys.release(region);
    var at: usize = 0;
    emit(region, &at, &.{0x55}); // push rbp
    switch (w) {
        .anon_chain => emit(region, &at, &.{ 0x48, 0x89, 0xe5 }), // mov rbp, rsp
        .anon_zero => emit(region, &at, &.{ 0x31, 0xed }), // xor ebp, ebp
        .anon_unaligned => emit(region, &at, &.{ 0xbd, 0x01, 0x00, 0x00, 0x00 }), // mov ebp, 1
        .anon_below => emit(region, &at, &.{ 0x48, 0xbd, 0, 0, 0, 0, 0, 0x70, 0, 0 }), // movabs rbp, 0x700000000000
        .anon_outside => emit(region, &at, &.{ 0x48, 0xbd, 0xf0, 0xef, 0xff, 0xff, 0xff, 0x7f, 0, 0 }), // movabs rbp, 0x7fffffffeff0
        .anon_invalid => emit(region, &at, &.{
            0x48, 0x89, 0xe5, // mov rbp, rsp
            0x48, 0x8b, 0x55, 0x08, // mov rdx, [rbp+8]
            0x48, 0xc7, 0x45, 0x08, 0x00, 0x10, 0x00, 0x00, // mov qword [rbp+8], 0x1000
        }),
        else => unreachable,
    }
    emit(region, &at, &.{ 0xb9, 0x00, 0x84, 0xd7, 0x17, 0xff, 0xc9, 0x75, 0xfc }); // mov ecx, 400000000; dec ecx; jnz
    if (w == .anon_invalid) emit(region, &at, &.{ 0x48, 0x89, 0x55, 0x08 }); // mov [rbp+8], rdx
    emit(region, &at, &.{ 0x5d, 0xc3 }); // pop rbp; ret
    if (mprotect(region.ptr, region.len, 5) != 0) return error.MprotectFailed; // read and execute
    anon_region = region;
}

fn releaseAnon() void {
    if (anon_region) |region| sys.release(region);
    anon_region = null;
}

noinline fn callAnon() u64 {
    const region = anon_region orelse return 0;
    const f: *const fn () callconv(.c) void = @ptrCast(@alignCast(region.ptr));
    f();
    return 1;
}

/// `levels` frames of recursion on top of the workload, so the stack is deep. The `+% 1` after
/// the call keeps it from being a tail call.
noinline fn deep(levels: u32, marker: *u8, workload: Workload) u64 {
    if (levels == 0) return switch (workload) {
        .spin => spin(40_000_000, marker),
        .syscalls => syscallSpin(3_000_000),
        .faults => faultSpin(),
        .anon_chain, .anon_zero, .anon_unaligned, .anon_below, .anon_outside, .anon_invalid => callAnon(),
    };
    return deep(levels - 1, marker, workload) +% 1;
}

const Prepared = struct {
    registry: unwind.registry.Registry,
    built: tables.Built,

    fn deinit(self: *Prepared) void {
        self.registry.deinit();
    }
};

/// The tables of this process, as the agent would build them.
fn prepare(pid: u32) !Prepared {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pm = procmaps.ProcessMaps.init(testing.allocator, pid);
    defer pm.deinit();
    const regions = try pm.read(arena.allocator());

    var registry = unwind.registry.Registry.init(testing.allocator, 262_144, 256);
    errdefer registry.deinit();
    const built = try tables.build(testing.allocator, &registry, pid, regions);
    return .{ .registry = registry, .built = built };
}

fn skipWithoutPrivilege(e: anyerror) anyerror {
    if (e == error.PermissionDenied or e == error.NotSupported) return error.SkipZigTest;
    return e;
}

test "the BPF program finds the same table row as userspace for the interrupted instruction" {
    const pid = sys.currentPid();
    var prepared = try prepare(pid);
    defer prepared.deinit();

    var probe = ebpf.unwindprobe.LookupProbe.init(testing.allocator) catch |e| return skipWithoutPrivilege(e);
    defer probe.deinit();

    // Tables first, then the process entry, then sampling.
    var maps = try probe.tables();
    defer maps.deinit();
    try maps.writeModulesFrom(prepared.registry.set, 0);
    try maps.writeProcess(pid, prepared.built.entry);
    try probe.begin(pid, 999);

    var marker: u8 = 0;
    std.mem.doNotOptimizeAway(spin(300_000_000, &marker));
    try probe.pause();

    var samples: u64 = 0;
    var found: u64 = 0;
    var checked: usize = 0;
    var steps_rows: u64 = 0;
    for (0..ebpf.unwindprobe.max_cpus) |cpu| {
        const slot = try probe.slot(@intCast(cpu));
        if (slot.samples == 0) continue;
        samples += slot.samples;
        found += slot.found;
        if (slot.found == 0) continue;
        steps_rows = @max(steps_rows, slot.row_steps);

        // The last sample that found a row: userspace finds the very same one.
        const mapping = unwind.procmap.find(&prepared.built.entry, slot.found_ip) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u64, mapping.module), slot.found_module);
        try testing.expectEqual(slot.found_ip -% mapping.bias, slot.found_file_addr);
        const row = prepared.registry.set.find(mapping.module, slot.found_file_addr) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u64, row.pc), slot.row_pc);
        try testing.expectEqual(@as(u64, row.cfa_type), slot.row_cfa_type);
        try testing.expectEqual(@as(i64, row.cfa_offset), slot.row_cfa_offset);
        try testing.expectEqual(@as(u64, row.rbp_type), slot.row_rbp_type);
        try testing.expectEqual(@as(i64, row.rbp_offset), slot.row_rbp_offset);
        checked += 1;
    }
    std.debug.print("lookup: {d} samples, {d} found a row, {d} CPUs compared in detail, up to {d} row steps\n", .{ samples, found, checked, steps_rows });
    try testing.expect(samples >= 100);
    try testing.expect(found * 10 >= samples * 9);
    try testing.expect(checked >= 1);
}

test "one unwind step in BPF gives the caller that userspace computes from the same stack" {
    const pid = sys.currentPid();
    var prepared = try prepare(pid);
    defer prepared.deinit();

    var probe = ebpf.unwindprobe.StepProbe.init(testing.allocator) catch |e| return skipWithoutPrivilege(e);
    defer probe.deinit();

    var maps = try probe.tables();
    defer maps.deinit();
    try maps.writeModulesFrom(prepared.registry.set, 0);
    try maps.writeProcess(pid, prepared.built.entry);
    try probe.begin(pid, 999);

    var samples: u64 = 0;
    var ok: u64 = 0;
    var failed: u64 = 0;
    var ended: u64 = 0;
    var compared: usize = 0;
    var marker: u8 = 0;

    for (0..6) |_| {
        try probe.setTarget(pid);
        std.mem.doNotOptimizeAway(spin(40_000_000, &marker));
        try probe.pause();

        for (0..ebpf.unwindprobe.max_cpus) |cpu| {
            const slot = try probe.slot(@intCast(cpu));
            if (slot.samples == 0) continue;
            if (slot.ok == 0 or slot.snapshot_ok == 0) continue;

            // The same inputs, the userspace code: the registers, the row, the stack bytes.
            const mapping = unwind.procmap.find(&prepared.built.entry, slot.ip) orelse return error.TestUnexpectedResult;
            const row = prepared.registry.set.find(mapping.module, slot.ip -% mapping.bias) orelse return error.TestUnexpectedResult;
            const stack = unwind.frame.Stack{ .base = slot.sp, .bytes = std.mem.sliceAsBytes(&slot.stack) };
            const next = try unwind.compact.unwind(row, .{ .pc = slot.ip, .sp = slot.sp, .bp = slot.bp }, stack);
            switch (next) {
                .end => return error.TestUnexpectedResult,
                .caller => |caller| {
                    try testing.expectEqual(caller.pc, slot.caller_pc);
                    try testing.expectEqual(caller.sp, slot.caller_sp);
                    try testing.expectEqual(caller.bp, slot.caller_bp);
                },
            }
            // And the caller makes sense on its own: above our frame, in code that has a table row.
            try testing.expect(slot.caller_sp > slot.sp and slot.caller_sp - slot.sp < 4096);
            const caller_mapping = unwind.procmap.find(&prepared.built.entry, slot.caller_pc) orelse return error.TestUnexpectedResult;
            try testing.expect(prepared.registry.set.find(caller_mapping.module, slot.caller_pc -% caller_mapping.bias) != null);
            compared += 1;
        }
    }

    // The counters are cumulative over the rounds; read them once at the end.
    for (0..ebpf.unwindprobe.max_cpus) |cpu| {
        const slot = try probe.slot(@intCast(cpu));
        samples += slot.samples;
        ok += slot.ok;
        failed += slot.failed;
        ended += slot.ended;
    }
    std.debug.print("step: {d} samples, {d} stepped ({d} ended, {d} failed), {d} samples compared against userspace\n", .{ samples, ok, ended, failed, compared });
    try testing.expect(ok * 10 >= samples * 9);
    try testing.expectEqual(@as(u64, 0), failed);
    try testing.expect(compared >= 6);
}

/// What a test expects of its walks.
const Expect = struct {
    /// The stop that at least 90% of the walks end with; null when it is not fixed.
    stop: ?Stop = null,
    min_frames: u64 = 1,
    kernel: KernelShare = .dont_care,
    /// At least one compared walk went through the frame pointer chain.
    frame_pointer: bool = false,
};

const WalkTally = struct {
    seen: [ebpf.unwindprobe.max_cpus]u64 = [_]u64{0} ** ebpf.unwindprobe.max_cpus,
    compared: usize = 0,
    complete: usize = 0,
    longest: u64 = 0,
    kernel: usize = 0,
    after_syscall: usize = 0,
    fp_walks: usize = 0,
};

const Stop = unwind.compactwalk.Stop;

/// Compares the last walk of every CPU with the userspace twin, run on the same registers and
/// the same stack bytes. It is a separate function on purpose: the frame of the test itself is
/// on the stack the BPF program walks, and the copy of that stack has a limited size, so big
/// locals must not live there.
noinline fn compareWalks(probe: *ebpf.unwindprobe.WalkProbe, prepared: *Prepared, tally: *WalkTally) !void {
    for (0..ebpf.unwindprobe.max_cpus) |cpu| {
        const slot = try probe.slot(@intCast(cpu));
        if (slot.walks == 0) continue;
        // A CPU that did not sample in this round still holds an old walk: compare each once.
        if (slot.walks == tally.seen[cpu]) continue;
        tally.seen[cpu] = slot.walks;

        const bytes = std.mem.sliceAsBytes(&slot.snapshot)[0..@intCast(slot.snapshot_len)];
        const stack = unwind.frame.Stack{ .base = slot.start_sp, .bytes = bytes };

        var expected: [ebpf.unwindprobe.max_frames]u64 = undefined;
        const twin = unwind.compactwalk.walk(
            &prepared.built.entry,
            &prepared.registry.set,
            .{ .pc = slot.start_pc, .sp = slot.start_sp, .bp = slot.start_bp },
            stack,
            &expected,
            .{ .innermost_is_return_address = slot.leaf_is_return == 1 },
        );
        const n = twin.count;
        const count: usize = @intCast(slot.count);

        std.debug.print("  cpu {d}: snapshot {d} bytes, stack depth to the last frame {d} bytes, twin {d} frames ({s}, {d} fp steps), BPF {d} frames (stop {d}, {d} fp steps)\n", .{ cpu, slot.snapshot_len, slot.sp -% slot.start_sp, n, @tagName(twin.stop), twin.fp_steps, slot.count, slot.stop, slot.fp_steps });

        if (slot.kernel == 1) {
            tally.kernel += 1;
            // The two bytes before a return address into user code from the kernel are `syscall`
            // (0f 05); in the little-endian word they are its top 16 bits.
            const after_syscall = (slot.code_before >> 48) == 0x050f;
            if (after_syscall) tally.after_syscall += 1;
            // The leaf is a return address exactly when the sample is inside a system call.
            try testing.expectEqual(@as(u64, @intFromBool(after_syscall)), slot.leaf_is_return);
        } else {
            try testing.expectEqual(@as(u64, 0), slot.leaf_is_return);
        }

        if (twin.stop != .outside_stack) {
            // The twin walked to a real end: the BPF walk is the same, frame for frame.
            try testing.expectEqual(n, count);
            try testing.expectEqualSlices(u64, expected[0..n], slot.frames[0..count]);
            try testing.expectEqual(@as(u64, @intFromEnum(twin.stop)), slot.stop);
            try testing.expectEqual(@as(u64, twin.fp_steps), slot.fp_steps);
            try testing.expectEqual(unwind.compactwalk.hashStack(expected[0..n], twin.stop, slot.leaf_is_return == 1), slot.hash);
            tally.complete += 1;
        } else {
            // The twin ran off the end of the copied stack, which BPF read in full: the BPF walk
            // has at least these frames. If it ended at the same place for the same reason, the
            // two agree completely.
            try testing.expect(count >= n);
            try testing.expectEqualSlices(u64, expected[0..n], slot.frames[0..n]);
            if (count == n and slot.stop == @intFromEnum(Stop.outside_stack)) tally.complete += 1;
        }
        if (slot.fp_steps > 0) tally.fp_walks += 1;
        tally.longest = @max(tally.longest, slot.count);
        tally.compared += 1;
    }
}

noinline fn reportWalks(probe: *ebpf.unwindprobe.WalkProbe, tally: *const WalkTally, want: Expect) !void {
    var walks: u64 = 0;
    var kernel_walks: u64 = 0;
    var stops = [_]u64{0} ** 16;
    for (0..ebpf.unwindprobe.max_cpus) |cpu| {
        const slot = try probe.slot(@intCast(cpu));
        walks += slot.walks;
        kernel_walks += slot.kernel_walks;
        for (slot.stops, 0..) |c, i| stops[i] += c;
    }
    std.debug.print("walk: {d} walks, {d} compared, {d} of them complete, {d} through the frame pointer chain, longest {d} frames; stops:", .{ walks, tally.compared, tally.complete, tally.fp_walks, tally.longest });
    for (stops, 0..) |c, i| {
        if (c == 0) continue;
        const name = if (std.enums.fromInt(Stop, i)) |s| @tagName(s) else "?";
        std.debug.print(" {s} {d}", .{ name, c });
    }
    std.debug.print("\n", .{});
    std.debug.print("kernel: {d} of {d} walks started in kernel mode; of {d} compared, {d} follow a syscall instruction\n", .{ kernel_walks, walks, tally.kernel, tally.after_syscall });

    try testing.expect(walks >= 100);
    try testing.expect(tally.compared >= 6);
    try testing.expectEqual(tally.compared, tally.complete);
    try testing.expect(tally.longest >= want.min_frames);
    try testing.expectEqual(@as(u64, 0), stops[@intFromEnum(Stop.chain)]);
    if (want.stop) |s| try testing.expect(stops[@intFromEnum(s)] * 10 >= walks * 9);
    if (want.frame_pointer) try testing.expect(tally.fp_walks >= 1);
    switch (want.kernel) {
        .dont_care => {},
        .syscalls => {
            try testing.expect(kernel_walks * 4 >= walks);
            try testing.expect(tally.kernel >= 1);
            try testing.expect(tally.after_syscall * 10 >= tally.kernel * 8);
        },
        .faults => {
            try testing.expect(kernel_walks * 4 >= walks);
            try testing.expect(tally.kernel - tally.after_syscall >= 1);
        },
    }
}

/// Everything the walk test needs, on the heap and set up by `noinline` functions: the test's own
/// frame is on the stack the BPF program walks, and the stack bytes it copies are limited, so
/// that frame has to stay small (a Debug build gives every by-value temporary its own slot).
const WalkFixture = struct {
    prepared: Prepared,
    probe: ebpf.unwindprobe.WalkProbe,
    maps: ebpf.tablemaps.TableMaps,
    tally: WalkTally,

    noinline fn setup(self: *WalkFixture, pid: u32) !void {
        self.tally = .{};
        self.prepared = try prepare(pid);
        errdefer self.prepared.deinit();
        self.probe = try ebpf.unwindprobe.WalkProbe.init(testing.allocator);
        errdefer self.probe.deinit();
        self.maps = try self.probe.tables();
        errdefer self.maps.deinit();
        try self.maps.writeModulesFrom(self.prepared.registry.set, 0);
        try self.maps.writeProcess(pid, self.prepared.built.entry);
        try self.probe.begin(pid, 999);
    }

    noinline fn teardown(self: *WalkFixture) void {
        self.maps.deinit();
        self.probe.deinit();
        self.prepared.deinit();
    }
};

fn runWalkTest(levels: u32, workload: Workload, want: Expect) !void {
    defer releaseFaults();
    defer releaseAnon();
    // Generated code has to exist before the tables are built, or its mapping is not in them.
    if (isAnon(workload)) try makeAnon(workload);

    const pid = sys.currentPid();
    const fixture = try testing.allocator.create(WalkFixture);
    defer testing.allocator.destroy(fixture);
    fixture.setup(pid) catch |e| return skipWithoutPrivilege(e);
    defer fixture.teardown();

    var marker: u8 = 0;
    for (0..6) |_| {
        try fixture.probe.setTarget(pid);
        std.mem.doNotOptimizeAway(deep(levels, &marker, workload));
        try fixture.probe.pause();
        try compareWalks(&fixture.probe, &fixture.prepared, &fixture.tally);
    }
    try reportWalks(&fixture.probe, &fixture.tally, want);
}

const Child = enum { busy_user, busy_kernel };

/// The same walk comparison on another process, with real glibc code: tables are built for the
/// child, and this process only waits (it spins) while the child runs and is sampled.
fn runChildTest(kind: Child, want: Expect) !void {
    const fixture = try testing.allocator.create(WalkFixture);
    defer testing.allocator.destroy(fixture);

    const child = switch (kind) {
        .busy_user => try sys.spawnBusyUser(),
        .busy_kernel => try sys.spawnBusyKernel(),
    };
    defer sys.reap(child);
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try procmaps.waitForProgram(arena.allocator(), child, switch (kind) {
            .busy_user => "/dash",
            .busy_kernel => "/dd",
        });
    }

    fixture.setup(child) catch |e| return skipWithoutPrivilege(e);
    defer fixture.teardown();

    var marker: u8 = 0;
    for (0..6) |_| {
        try fixture.probe.setTarget(child);
        std.mem.doNotOptimizeAway(spin(40_000_000, &marker));
        try fixture.probe.pause();
        try compareWalks(&fixture.probe, &fixture.prepared, &fixture.tally);
    }
    try reportWalks(&fixture.probe, &fixture.tally, want);
}

test "the BPF walk gives the same frames as the userspace twin on the same stack" {
    try runWalkTest(0, .spin, .{ .min_frames = 6 });
}

test "a walk that reaches the frame limit stops there and still matches the twin" {
    try runWalkTest(200, .spin, .{ .stop = .truncated, .min_frames = 128 });
}

test "a sample taken inside a system call starts at the return address" {
    try runWalkTest(0, .syscalls, .{ .min_frames = 6, .kernel = .syscalls });
}

test "a sample taken in a page fault starts at the faulting instruction" {
    try runWalkTest(0, .faults, .{ .min_frames = 6, .kernel = .faults });
}

test "generated code without tables is left through the frame pointer chain" {
    try runWalkTest(0, .anon_chain, .{ .min_frames = 6, .frame_pointer = true });
}

test "generated code with a zero frame pointer ends the stack there" {
    try runWalkTest(0, .anon_zero, .{ .stop = .end });
}

test "generated code with an unaligned frame pointer is refused" {
    try runWalkTest(0, .anon_unaligned, .{ .stop = .bad_frame_pointer });
}

test "generated code whose return address points nowhere leaves that address out" {
    try runWalkTest(0, .anon_invalid, .{ .stop = .invalid_address });
}

test "walks of a shell busy loop (user mode, glibc and dash frames) match the twin" {
    try runChildTest(.busy_user, .{ .stop = .end, .min_frames = 5 });
}

test "walks of dd (kernel mode inside glibc's read and write) match the twin" {
    try runChildTest(.busy_kernel, .{ .stop = .end, .min_frames = 5, .kernel = .syscalls });
}

test "generated code with a frame pointer below the stack pointer is refused" {
    try runWalkTest(0, .anon_below, .{ .stop = .bad_frame_pointer });
}

test "generated code with a frame pointer into unmapped memory stops the walk" {
    try runWalkTest(0, .anon_outside, .{ .stop = .outside_stack });
}

test "ring buffer: one record per sample arrives, in order on every CPU, none lost" {
    var probe = ebpf.ringprobe.RingProbe.init(testing.allocator) catch |e| return skipWithoutPrivilege(e);
    defer probe.deinit();

    const pid = sys.currentPid();
    try probe.begin(pid, 999);
    var marker: u8 = 0;
    var read: usize = 0;
    for (0..3) |_| {
        std.mem.doNotOptimizeAway(spin(100_000_000, &marker));
        read += try probe.consume();
    }
    try probe.pause();
    read += try probe.consume();

    var sent: u64 = 0;
    var dropped: u64 = 0;
    for (0..ebpf.ringprobe.max_cpus) |cpu| {
        const counters = try probe.counter(@intCast(cpu));
        sent += counters.sent;
        dropped += counters.dropped;
    }

    // Records of one CPU come out in the order they were sent: the numbers have no gaps.
    var next = [_]u64{0} ** ebpf.ringprobe.max_cpus;
    for (probe.records()) |record| {
        try testing.expectEqual(pid, record.tgid);
        try testing.expect(record.cpu < ebpf.ringprobe.max_cpus);
        try testing.expectEqual(next[record.cpu], record.seq);
        next[record.cpu] += 1;
    }
    std.debug.print("ring: {d} records read, {d} sent by the program, {d} dropped\n", .{ read, sent, dropped });

    try testing.expect(read >= 100);
    try testing.expectEqual(read, probe.records().len);
    try testing.expectEqual(@as(u64, read), sent);
    try testing.expectEqual(@as(u64, 0), dropped);
    try testing.expectEqual(@as(usize, 0), probe.problems());
}

/// The production walk, set up like `WalkFixture`: tables for this process, then sampling.
const OncpuFixture = struct {
    prepared: Prepared,
    probe: ebpf.oncpuprobe.OncpuProbe,
    maps: ebpf.tablemaps.TableMaps,

    noinline fn setup(self: *OncpuFixture, pid: u32) !void {
        self.prepared = try prepare(pid);
        errdefer self.prepared.deinit();
        self.probe = try ebpf.oncpuprobe.OncpuProbe.init(testing.allocator);
        errdefer self.probe.deinit();
        self.maps = try self.probe.tables();
        errdefer self.maps.deinit();
        try self.maps.writeModulesFrom(self.prepared.registry.set, 0);
        try self.maps.writeProcess(pid, self.prepared.built.entry);
        try self.probe.begin(pid, 999);
    }

    noinline fn teardown(self: *OncpuFixture) void {
        self.maps.deinit();
        self.probe.deinit();
        self.prepared.deinit();
    }
};

/// Walks of this process through the production program. Every record must carry the hash of
/// its own frames, and the counters of the program must add up with what came out of the ring.
fn runOncpuTest(levels: u32, want_stop: Stop, min_frames: usize) !void {
    const pid = sys.currentPid();
    const fixture = try testing.allocator.create(OncpuFixture);
    defer testing.allocator.destroy(fixture);
    fixture.setup(pid) catch |e| return skipWithoutPrivilege(e);
    defer fixture.teardown();

    var marker: u8 = 0;
    var read: usize = 0;
    for (0..4) |_| {
        try fixture.probe.setTarget(pid);
        std.mem.doNotOptimizeAway(deep(levels, &marker, .spin));
        try fixture.probe.pause();
        read += try fixture.probe.consume();
    }

    var drained: std.ArrayList(ebpf.oncpuprobe.Drained) = .empty;
    defer drained.deinit(testing.allocator);
    try fixture.probe.drain(testing.allocator, &drained);
    read += try fixture.probe.consume();

    const totals = try fixture.probe.totals();
    const stacks = fixture.probe.stacks();
    var by_stop = [_]usize{0} ** 16;
    var longest: usize = 0;
    for (stacks) |*stack| {
        try testing.expectEqual(pid, stack.tgid);
        const expected = unwind.compactwalk.hashStackWithKernel(stack.user(), stack.kernel(), @enumFromInt(stack.stop), (stack.flags & 1) != 0);
        try testing.expectEqual(expected, stack.hash);
        by_stop[stack.stop] += 1;
        longest = @max(longest, stack.count);
    }

    std.debug.print("oncpu: {d} walks: {d} sent as records, {d} only counted, {d} dropped, {d} map full; longest {d} frames; stops:", .{ totals.walks, totals.sent, totals.repeats, totals.dropped, totals.map_full, longest });

    for (by_stop, 0..) |n, i| {
        if (n == 0) continue;
        std.debug.print(" {s} {d}", .{ if (std.enums.fromInt(Stop, i)) |s| @tagName(s) else "?", n });
    }
    std.debug.print("\n", .{});

    try testing.expectEqual(totals.walks, totals.sent + totals.repeats + totals.dropped);
    try testing.expectEqual(@as(u64, 0), totals.dropped);
    try testing.expectEqual(@as(u64, 0), totals.map_full);
    try testing.expect(totals.repeats > totals.walks / 2);

    // Every sample is attributed: the drained counts add up to all walks except the named losses,
    // and each drained stack has its frames in the ring.
    var weight: u64 = 0;
    for (drained.items) |entry| {
        try testing.expect(entry.count >= 1);
        try testing.expectEqual(pid, entry.key.tgid);
        var found = false;
        for (stacks) |*stack| {
            if (stack.hash == entry.key.hash and stack.tgid == entry.key.tgid) found = true;
        }
        try testing.expect(found);
        weight += entry.count;
    }
    try testing.expectEqual(totals.walks - totals.dropped - totals.map_full, weight);
    try testing.expect(drained.items.len > 0 and drained.items.len <= stacks.len);

    try testing.expectEqual(@as(u64, read), totals.sent);
    try testing.expectEqual(stacks.len, read);
    try testing.expectEqual(@as(usize, 0), fixture.probe.problems());
    try testing.expectEqual(@as(u64, 0), totals.stops[@intFromEnum(Stop.chain)]);
    try testing.expect(by_stop[@intFromEnum(want_stop)] * 10 >= stacks.len * 9);
    try testing.expect(longest >= min_frames);
}

test "production walk: a shallow stack arrives as a record that carries its own hash" {
    try runOncpuTest(0, .no_function, 6);
}

test "production walk: a stack longer than the frame limit is cut there and says so" {
    try runOncpuTest(200, .truncated, 128);
}

test "production walk: counts read while sampling only grow and add up to every walk" {
    const pid = sys.currentPid();
    const fixture = try testing.allocator.create(OncpuFixture);
    defer testing.allocator.destroy(fixture);
    fixture.setup(pid) catch |e| return skipWithoutPrivilege(e);
    defer fixture.teardown();

    var last = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer last.deinit();

    // Snapshots between bursts of work, while the program stays attached and keeps sampling.
    var marker: u8 = 0;
    for (0..6) |_| {
        std.mem.doNotOptimizeAway(deep(0, &marker, .spin));
        var snap: std.ArrayList(ebpf.oncpuprobe.Drained) = .empty;
        defer snap.deinit(testing.allocator);
        try fixture.probe.snapshot(testing.allocator, &snap);
        for (snap.items) |entry| {
            const before = last.get(entry.key.hash) orelse 0;
            try testing.expect(entry.count >= before);
            try last.put(entry.key.hash, entry.count);
        }
    }

    try fixture.probe.pause();
    const read = try fixture.probe.consume();
    var final: std.ArrayList(ebpf.oncpuprobe.Drained) = .empty;
    defer final.deinit(testing.allocator);
    try fixture.probe.snapshot(testing.allocator, &final);

    const totals = try fixture.probe.totals();
    const stacks = fixture.probe.stacks();
    var weight: u64 = 0;
    for (final.items) |entry| {
        const before = last.get(entry.key.hash) orelse 0;
        try testing.expect(entry.count >= before);
        var found = false;
        for (stacks) |*stack| {
            if (stack.hash == entry.key.hash and stack.tgid == entry.key.tgid) found = true;
        }
        try testing.expect(found);
        weight += entry.count;
    }

    std.debug.print("snapshots: {d} walks, {d} stacks, weight {d} (dropped {d}, map full {d})\n", .{ totals.walks, final.items.len, weight, totals.dropped, totals.map_full });
    try testing.expect(totals.walks >= 100);
    try testing.expectEqual(totals.walks - totals.dropped - totals.map_full, weight);
    try testing.expectEqual(@as(u64, read), totals.sent);
    try testing.expectEqual(@as(u64, 0), totals.dropped);
}

test "production walk: samples taken in the kernel carry their kernel frames" {
    const pid = sys.currentPid();
    const fixture = try testing.allocator.create(OncpuFixture);
    defer testing.allocator.destroy(fixture);
    fixture.setup(pid) catch |e| return skipWithoutPrivilege(e);
    defer fixture.teardown();

    // A tight loop of cheap system calls spends most of its time in the kernel.
    var read: usize = 0;
    for (0..3) |_| {
        try fixture.probe.setTarget(pid);
        var i: usize = 0;
        while (i < 2_000_000) : (i += 1) std.mem.doNotOptimizeAway(std.os.linux.getppid());
        try fixture.probe.pause();
        read += try fixture.probe.consume();
    }

    const totals = try fixture.probe.totals();
    const stacks = fixture.probe.stacks();
    var with_kernel: usize = 0;
    var deepest: usize = 0;
    var kernel_mode_without: usize = 0;
    for (stacks) |*stack| {
        const expected = unwind.compactwalk.hashStackWithKernel(stack.user(), stack.kernel(), @enumFromInt(stack.stop), (stack.flags & 1) != 0);
        try testing.expectEqual(expected, stack.hash);
        if (stack.kcount > 0) {
            with_kernel += 1;
            deepest = @max(deepest, stack.kcount);
            try testing.expect((stack.flags & 2) != 0);
            for (stack.kernel()) |pc| try testing.expect(pc >= 0xffff000000000000);
        }
        if ((stack.flags & 2) == 0) try testing.expectEqual(@as(u8, 0), stack.kcount);
        if ((stack.flags & 2) != 0 and stack.kcount == 0) kernel_mode_without += 1;
    }

    std.debug.print("kernel: {d} walks ({d} in kernel mode), {d} records, {d} with kernel frames, deepest {d}\n", .{ totals.walks, totals.kernel_walks, stacks.len, with_kernel, deepest });
    std.debug.print("{d} kernel-mode records without kernel frames", .{kernel_mode_without});
    try testing.expectEqual(@as(usize, 0), kernel_mode_without);
    try testing.expect(totals.kernel_walks > 0);
    try testing.expect(with_kernel > 0);
    try testing.expectEqual(@as(u64, read), totals.sent);
    try testing.expectEqual(@as(u64, 0), totals.dropped);
    try testing.expectEqual(@as(usize, 0), fixture.probe.problems());
}

test "collector: the windows deliver every sample with its frames, and the losses are named" {
    const pid = sys.currentPid();
    var prepared = try prepare(pid);
    defer prepared.deinit();
    var collector = ebpf.oncpu.OnCpu.init(testing.allocator) catch |e| return skipWithoutPrivilege(e);
    defer collector.deinit();

    var maps = try collector.tables();
    defer maps.deinit();
    try maps.writeModulesFrom(prepared.registry.set, 0);
    try maps.writeProcess(pid, prepared.built.entry);
    collector.start(pid, 999) catch |e| return skipWithoutPrivilege(e);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var delivered: u64 = 0;
    var by_stop = [_]u64{0} ** 16;
    var dropped: u64 = 0;
    var map_full: u64 = 0;
    var marker: u8 = 0;

    for (0..6) |round| {
        if (round < 5) {
            std.mem.doNotOptimizeAway(deep(0, &marker, .spin));
        } else {
            // The last window is read with sampling off, so nothing is in flight.
            try collector.probe.pause();
        }
        const window = try collector.collect(arena.allocator());

        var sum: u64 = 0;
        for (window.stacks, 0..) |stack, i| {
            sum += stack.samples;
            if (i > 0) try testing.expect(window.stacks[i - 1].samples >= stack.samples);
            try testing.expect(stack.user.len > 0);
        }
        try testing.expectEqual(window.samples, sum);
        var by_stop_sum: u64 = 0;
        for (window.lost.by_stop) |n| by_stop_sum += n;
        try testing.expectEqual(window.samples, by_stop_sum);
        try testing.expectEqual(@as(u64, 0), window.lost.held_back);
        try testing.expectEqual(@as(u64, 0), window.lost.bad_records);

        delivered += window.samples;
        dropped += window.lost.dropped;
        map_full += window.lost.map_full;
        for (window.lost.by_stop, 0..) |n, i| by_stop[i] += n;
    }

    const totals = try collector.probe.totals();
    std.debug.print("collector: {d} walks, {d} samples delivered, dropped {d}, map full {d}; by stop:", .{ totals.walks, delivered, dropped, map_full });
    for (by_stop, 0..) |n, i| {
        if (n > 0) std.debug.print(" {s} {d}", .{ ebpf.oncpu.StackLoss.stopName(i), n });
    }
    std.debug.print("\n", .{});

    try testing.expect(totals.walks >= 100);
    try testing.expectEqual(totals.walks - totals.dropped - totals.map_full, delivered);
    try testing.expectEqual(totals.dropped, dropped);
    try testing.expectEqual(totals.map_full, map_full);
    try testing.expectEqual(@as(u64, 0), dropped);
    try testing.expect(by_stop[@intFromEnum(Stop.no_function)] * 10 >= delivered * 9);
}
