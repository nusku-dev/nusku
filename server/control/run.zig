//! One profiling run: `agent.profile` on a thread of its own, with the run as its context. The
//! report callback and the binary hooks are how the agent's data reaches the server.

const std = @import("std");
const agent = @import("agent");
const Server = @import("../server.zig").Server;
const TargetId = @import("../store/store.zig").TargetId;
const upload_file = @import("../symbolize/upload.zig");
const Upload = upload_file.Upload;

/// One profiling run. Its address must not change while the thread lives: the thread points
/// into it, so the controller keeps all of them in one array that is never resized.
pub const Run = struct {
    active: bool,
    server: *Server,
    target: TargetId,
    thread: std.Thread,
    cancel: agent.Cancel,
    options: agent.Options,
    /// A report is copied here before it goes to the server: `window_bytes_max` bytes.
    scratch: []align(8) u8,
    /// Written by the thread before it ends: read it after `join`.
    result: anyerror!agent.StopReason,

    /// The hooks below have no allocator argument, so the run keeps the one it was started with.
    gpa: std.mem.Allocator,
    /// The binary that is arriving now, if any. Only this run's thread touches it.
    upload: Upload,
    /// What the server gave this run for the binary arriving now: null when none is.
    ticket: ?Server.Ticket,

    pub fn thread_main(run: *Run) void {
        run.result = agent.profile(run.gpa, run.options, run, on_report);
    }

    /// Called by `agent.profile` on the run's thread, once per interval. An error stops the run.
    pub fn on_report(run: *Run, report: *const agent.Report) !void {
        var fixed = std.heap.FixedBufferAllocator.init(run.scratch);
        const message = agent.Message.from_report(fixed.allocator(), report) catch {
            // Too big for the scratch: counted with the target, so a profile shows the loss.
            run.server.window_dropped(run.target) catch {};
            return;
        };
        run.server.ingest(run.target, &message) catch |err| switch (err) {
            error.WindowTooLarge => {}, // The store counts it; the run goes on.
            else => return err,
        };
    }

    /// The agent asks before it sends a binary.
    pub fn binary_known(run: *Run, build_id: []const u8) bool {
        return run.server.binary_known(build_id);
    }

    /// Claims the binary and reserves its bytes, then gets ready for its chunks. Refused
    /// (`AlreadyKnown`) when another run is sending the same binary since this one asked.
    pub fn binary_begin(run: *Run, header: *const agent.binary.Header) !void {
        if (run.ticket != null) {
            run.binary_abort(); // A begin with no end: the agent lost track. Start clean.
            return error.OutOfOrder;
        }
        const bytes = try upload_file.bytes_of(header);
        if (bytes > run.upload.bytes_max) return error.TooLarge;
        run.ticket = try run.server.upload_start(header.build_id, bytes);
        errdefer run.ticket_drop();
        try run.upload.begin(run.gpa, header);
    }

    pub fn binary_chunk(run: *Run, chunk: *const agent.binary.Chunk) !void {
        try run.upload.chunk(run.gpa, chunk);
    }

    /// Hands the binary to the server, which builds its table on a thread of its own: the
    /// agent's loop does not wait for it. An error here makes the agent drop this binary; the
    /// run goes on.
    pub fn binary_end(run: *Run) !void {
        const ticket = run.ticket orelse return error.OutOfOrder;
        const received = run.upload.end(run.gpa) catch |err| {
            run.ticket_drop();
            return err;
        };
        run.ticket = null;
        try run.server.upload_end(ticket, received);
    }

    /// The agent stopped in the middle of a binary (the file changed, or the run ends): the
    /// half that arrived is dropped, so the next binary starts clean.
    pub fn binary_abort(run: *Run) void {
        run.upload.abort(run.gpa);
        run.ticket_drop();
    }

    /// Gives the claim and the bytes back, if the run holds them.
    pub fn ticket_drop(run: *Run) void {
        const ticket = run.ticket orelse return;
        run.server.upload_abort(ticket);
        run.ticket = null;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "the hooks turn a received binary into a known one" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);

    // Only what the hooks use is set.
    var run: Run = undefined;
    run.server = &server;
    run.gpa = testing.allocator;
    run.upload = Upload.init(1 << 20);
    run.ticket = null;
    defer run.upload.deinit(testing.allocator);
    defer run.ticket_drop();

    try testing.expect(!run.binary_known("hook-id"));

    const header = agent.binary.Header{
        .build_id = "hook-id",
        .path = "/test",
        .segments = &.{},
        .sizes = .initFill(0),
    };
    try run.binary_begin(&header);
    // Claimed while it arrives: another run asking now is told not to send it.
    try testing.expect(run.binary_known("hook-id"));
    try testing.expectError(error.AlreadyKnown, server.upload_start("hook-id", 0));
    try run.binary_end();
    try testing.expect(run.ticket == null);
    try testing.expect(run.binary_known("hook-id"));

    // A chunk that does not fit what the header said is refused.
    var other = header;
    other.build_id = "other-id";
    try run.binary_begin(&other);
    const chunk = agent.binary.Chunk{ .section = .symtab, .offset = 0, .bytes = "abc" };
    try testing.expectError(error.Malformed, run.binary_chunk(&chunk));
}

test "an aborted binary is dropped, and the next one arrives whole" {
    var server: Server = undefined;
    try server.init(testing.allocator, .{
        .targets_max = 1,
        .windows_per_target_max = 2,
        .window_bytes_max = 1024,
    });
    defer server.deinit(testing.allocator);

    var run: Run = undefined;
    run.server = &server;
    run.gpa = testing.allocator;
    run.upload = Upload.init(1 << 20);
    run.ticket = null;
    defer run.upload.deinit(testing.allocator);
    defer run.ticket_drop();

    var sizes = std.EnumArray(agent.binary.Section, u64).initFill(0);
    sizes.set(.strtab, 4);
    const first = agent.binary.Header{
        .build_id = "first",
        .path = "/first",
        .segments = &.{},
        .sizes = sizes,
    };
    try run.binary_begin(&first);
    const half = agent.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "ab" };
    try run.binary_chunk(&half);
    run.binary_abort();
    try testing.expect(!run.upload.receiving);
    run.binary_abort(); // Nothing in flight: nothing to do.

    // Without the abort, this begin would find the first one still open and be refused.
    var second = first;
    second.build_id = "second";
    second.path = "/second";
    try run.binary_begin(&second);
    const whole = agent.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "abcd" };
    try run.binary_chunk(&whole);
    try run.binary_end();

    try testing.expect(!run.binary_known("first"));
    try testing.expect(run.binary_known("second"));
}
