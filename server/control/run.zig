//! One profiling run: `agent.profile` on a thread of its own. Its report callback and binary
//! hooks are how the agent's data reaches the server.

const std = @import("std");
const agent = @import("agent");
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;
const upload_file = @import("../symbolize/upload.zig");
const log_file = @import("../log.zig");

const log = log_file.server;
const Upload = upload_file.Upload;

pub const Run = struct {
    active: bool,
    server: *Server,
    target: TargetId,
    thread: std.Thread,
    cancel: agent.Cancel,
    options: agent.Options,
    /// Where a report is copied: `window_bytes_max` bytes.
    scratch: []align(8) u8,
    /// Written by the thread before it ends.
    result: anyerror!agent.StopReason,
    /// Set by the thread as its last act.
    finished: std.atomic.Value(bool),
    /// The hooks take no allocator: this one.
    gpa: std.mem.Allocator,
    /// The binary arriving now, if any.
    upload: Upload,
    /// The server's claim and budget for that binary.
    ticket: ?Server.Ticket,

    pub fn thread_main(run: *Run) void {
        run.result = agent.profile(run.gpa, run.options, run, on_report);
        run.finished.store(true, .release);
    }

    /// Once per interval, on the run's thread. An error stops the run.
    pub fn on_report(run: *Run, report: *const agent.Report) !void {
        var fixed = std.heap.FixedBufferAllocator.init(run.scratch);
        const message = agent.Message.from_report(fixed.allocator(), report) catch {
            run.server.window_dropped(run.target) catch {};
            return;
        };
        run.server.ingest(run.target, &message) catch |err| switch (err) {
            error.WindowTooLarge => {}, // Counted by the store; the run goes on.
            else => return err,
        };
    }

    pub fn binary_known(run: *Run, build_id: []const u8) bool {
        return run.server.binary_known(build_id);
    }

    /// Claims the binary and its bytes, then gets ready for its chunks. `AlreadyKnown` when
    /// another run started sending it since this one asked.
    pub fn binary_begin(run: *Run, header: *const agent.binary.Header) !void {
        if (run.ticket != null) {
            log.warn("binary refused: the last one never ended", .{ .path = header.path });
            run.binary_abort();
            return error.OutOfOrder;
        }
        const bytes = upload_file.bytes_of(header) catch std.math.maxInt(u64);
        if (bytes > run.upload.bytes_max) {
            log.warn("binary refused: too big to receive", .{
                .path = header.path,
                .kib = log_file.kib(bytes),
                .kib_max = log_file.kib(run.upload.bytes_max),
            });
            return error.TooLarge;
        }
        run.ticket = run.server.upload_start(header.build_id, header.path, bytes) catch |err| {
            if (err == error.AlreadyKnown) log.debug("binary already on its way", .{
                .path = header.path,
            });
            return err;
        };
        errdefer run.ticket_drop();
        try run.upload.begin(run.gpa, header);
        log.debug("binary arriving", .{ .path = header.path, .kib = log_file.kib(bytes) });
    }

    pub fn binary_chunk(run: *Run, chunk: *const agent.binary.Chunk) !void {
        try run.upload.chunk(run.gpa, chunk);
    }

    /// Hands the binary to the server, whose builder makes its table: the agent does not wait.
    pub fn binary_end(run: *Run) !void {
        const ticket = run.ticket orelse return error.OutOfOrder;
        const received = run.upload.end(run.gpa) catch |err| {
            run.ticket_drop();
            return err;
        };
        run.ticket = null;
        // Logged before the hand-over: the builder frees `received`.
        log.debug("binary received", .{ .path = received.path, .kib = log_file.kib(ticket.bytes) });
        try run.server.upload_end(ticket, received);
    }

    /// The agent stopped in the middle of a binary: what arrived is dropped.
    pub fn binary_abort(run: *Run) void {
        if (run.upload.receiving) log.debug("binary not received: the agent stopped sending", .{
            .path = run.upload.path,
        });
        run.upload.abort(run.gpa);
        run.ticket_drop();
    }

    pub fn ticket_drop(run: *Run) void {
        const ticket = run.ticket orelse return;
        run.server.upload_abort(ticket);
        run.ticket = null;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

/// A run with only what the binary hooks use.
fn run_hooks_only(server: *Server) Run {
    var run: Run = undefined;
    run.server = server;
    run.gpa = testing.allocator;
    run.upload = Upload.init(1 << 20);
    run.ticket = null;
    return run;
}

fn server_small(server: *Server) !void {
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
}

fn header_test(build_id: []const u8, strtab_bytes: u64) agent.binary.Header {
    var sizes = std.EnumArray(agent.binary.Section, u64).initFill(0);
    sizes.set(.strtab, strtab_bytes);
    return .{ .build_id = build_id, .path = "/test", .segments = &.{}, .sizes = sizes };
}

test "the hooks turn a received binary into a known one" {
    var server: Server = undefined;
    try server_small(&server);
    defer server.deinit(testing.allocator);
    var run = run_hooks_only(&server);
    defer run.upload.deinit(testing.allocator);
    defer run.ticket_drop();

    try testing.expect(!run.binary_known("hook-id"));
    try run.binary_begin(&header_test("hook-id", 0));
    // Claimed while it arrives: no other run may send it.
    try testing.expect(run.binary_known("hook-id"));
    try testing.expectError(error.AlreadyKnown, server.upload_start("hook-id", "/test", 0));
    try run.binary_end();
    try testing.expect(run.ticket == null);
    try testing.expect(run.binary_known("hook-id"));

    try run.binary_begin(&header_test("other-id", 0));
    const chunk = agent.binary.Chunk{ .section = .symtab, .offset = 0, .bytes = "abc" };
    try testing.expectError(error.Malformed, run.binary_chunk(&chunk));
}

test "an aborted binary is dropped, and the next one arrives whole" {
    var server: Server = undefined;
    try server_small(&server);
    defer server.deinit(testing.allocator);
    var run = run_hooks_only(&server);
    defer run.upload.deinit(testing.allocator);
    defer run.ticket_drop();

    try run.binary_begin(&header_test("first", 4));
    const half = agent.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "ab" };
    try run.binary_chunk(&half);
    run.binary_abort();
    try testing.expect(!run.upload.receiving);
    run.binary_abort(); // Nothing in flight: nothing to do.

    // Without the abort, this begin would find the first still open.
    try run.binary_begin(&header_test("second", 4));
    const whole = agent.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "abcd" };
    try run.binary_chunk(&whole);
    try run.binary_end();
    try testing.expect(!run.binary_known("first"));
    try testing.expect(run.binary_known("second"));
}
