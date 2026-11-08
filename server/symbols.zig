//! The symbols layer: the symbol tables of the agents' binaries, by build ID, and what names an
//! address with them. A binary arrives through a `Receiver`, one per agent run, under one
//! budget for all uploads; its table is built on the layer's own thread, so the run never waits.
//! Safe from any thread: its own lock guards it, held for bounded work. Stands on os.
//!   upload.zig        one binary arriving: begin, chunks, end, checked against its header
//!   builder.zig       a binary arrived whole, and the queue of those waiting for their table
//!   symbol_table.zig  a binary's functions, sorted by file offset
//!   binaries.zig      the tables, within a budget of entries and bytes: least recently used go
//!   id_set.zig        a few build IDs in fixed slots: the claims and the refusals

const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("shared").protocol;
const os = @import("os.zig");
const builder = @import("symbols/builder.zig");
const upload_file = @import("symbols/upload.zig");
const id_set = @import("symbols/id_set.zig");
const Binaries = @import("symbols/binaries.zig").Binaries;
const symbol_table = @import("symbols/symbol_table.zig");
const SymbolTable = symbol_table.SymbolTable;
const Input = symbol_table.Input;
const log_file = @import("log.zig");

const log = log_file.server;
const Received = builder.Received;
const Upload = upload_file.Upload;

pub const Options = struct {
    binaries_max: usize = 1024,
    /// All symbol tables together.
    binaries_bytes_max: u64 = 256 * 1024 * 1024,
    /// All uploads together, from their first chunk until their table is built.
    uploads_bytes_max: u64 = 1024 * 1024 * 1024,
    /// One binary's upload.
    upload_bytes_max: u64 = 512 * 1024 * 1024,
};

/// How the symbols are doing.
pub const Stats = struct {
    binaries: usize,
    binaries_bytes: u64,
    /// Waiting for the builder, or being built.
    builds_pending: usize,
    builds_failed: u64,
    uploads_bytes: u64,
};

/// One upload per run at most.
const uploads_max = 64;
const refused_max = 64;

/// What a receiver holds while a binary arrives: its claim on the build ID, and its bytes of
/// the upload budget.
const Ticket = struct {
    slot: id_set.IdSet(uploads_max).Slot,
    bytes: u64,
};

pub const Symbols = struct {
    gpa: std.mem.Allocator,
    lock: os.Lock,
    binaries: Binaries,
    /// Build IDs arriving now, one per upload.
    claims: id_set.IdSet(uploads_max),
    /// Binaries whose table was too big: sending them again would fail the same way.
    refused: id_set.IdSet(refused_max),
    uploads_bytes_max: u64,
    /// Held by uploads arriving, queued or being built.
    uploads_bytes_used: u64,
    upload_bytes_max: u64,
    /// Binaries waiting for their table, oldest first.
    builds: builder.Queue,
    /// The build ID being built now, or empty. Owned by the builder thread.
    building: []const u8,
    builds_failed: u64,
    /// Broadcast when a binary is queued, a build ends, or the layer stops.
    builds_changed: os.Condition,
    builds_stopping: bool,
    builder_thread: std.Thread,

    /// Starts the builder thread: the layer must stay at its address until `deinit`.
    pub fn init(symbols: *Symbols, gpa: std.mem.Allocator, options: Options) !void {
        symbols.* = .{
            .gpa = gpa,
            .lock = .{},
            .binaries = try Binaries.init(gpa, options.binaries_max, options.binaries_bytes_max),
            .claims = .{},
            .refused = .{},
            .uploads_bytes_max = options.uploads_bytes_max,
            .uploads_bytes_used = 0,
            .upload_bytes_max = options.upload_bytes_max,
            .builds = .{},
            .building = &.{},
            .builds_failed = 0,
            .builds_changed = .{},
            .builds_stopping = false,
            .builder_thread = undefined,
        };
        errdefer symbols.binaries.deinit(gpa);
        // Last: the thread reads the layer as soon as it runs.
        symbols.builder_thread = try std.Thread.spawn(.{}, builder_main, .{symbols});
    }

    /// Stops the builder after the build in progress, and frees everything. Binaries still
    /// queued are dropped.
    pub fn deinit(symbols: *Symbols) void {
        symbols.lock.lock();
        symbols.builds_stopping = true;
        symbols.builds_changed.broadcast();
        symbols.lock.unlock();
        symbols.builder_thread.join();

        log.info("symbols stopped", .{
            .binaries = symbols.binaries.count,
            .binaries_mib = symbols.binaries.bytes_used / (1024 * 1024),
            .builds_failed = symbols.builds_failed,
            .builds_dropped = symbols.builds.count,
        });
        while (symbols.builds.pop()) |received| {
            var owned = received;
            owned.deinit(symbols.gpa);
        }
        symbols.binaries.deinit(symbols.gpa);
        symbols.* = undefined;
    }

    /// The tables these regions need count as used, so eviction takes those nobody needs.
    pub fn used(symbols: *Symbols, regions: []const protocol.Region) void {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        for (regions) |region| {
            const build_id = region.build_id orelse continue;
            _ = symbols.binaries.get(build_id);
        }
    }

    /// The function at `offset` of binary `build_id`, copied into `arena`, or null.
    pub fn name(
        symbols: *Symbols,
        arena: std.mem.Allocator,
        build_id: []const u8,
        offset: u64,
    ) !?[]const u8 {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        const table = symbols.binaries.get(build_id) orelse return null;
        const hit = table.lookup(offset) orelse return null;
        return try arena.dupe(u8, hit.name);
    }

    /// Until every binary received so far has its table, or failed to get one.
    pub fn wait(symbols: *Symbols) void {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        while (symbols.builds.count > 0 or symbols.building.len > 0) {
            symbols.builds_changed.wait(&symbols.lock);
        }
    }

    pub fn stats(symbols: *Symbols) Stats {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        return .{
            .binaries = symbols.binaries.count,
            .binaries_bytes = symbols.binaries.bytes_used,
            .builds_pending = symbols.builds.count + @intFromBool(symbols.building.len > 0),
            .builds_failed = symbols.builds_failed,
            .uploads_bytes = symbols.uploads_bytes_used,
        };
    }

    /// True when a binary need not be sent: its table is here, will be, or was refused.
    fn known(symbols: *Symbols, build_id: []const u8) bool {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        return symbols.known_locked(build_id);
    }

    fn known_locked(symbols: *const Symbols, build_id: []const u8) bool {
        return symbols.binaries.has(build_id) or symbols.builds.has(build_id) or
            std.mem.eql(u8, symbols.building, build_id) or symbols.claims.has(build_id) or
            symbols.refused.has(build_id);
    }

    /// Claims `build_id` and reserves `bytes` of the upload budget.
    fn claim(
        symbols: *Symbols,
        build_id: []const u8,
        path: []const u8,
        bytes: u64,
    ) error{ Malformed, AlreadyKnown, UploadsFull }!Ticket {
        if (build_id.len == 0 or build_id.len > id_set.id_bytes_max) return error.Malformed;
        symbols.lock.lock();
        defer symbols.lock.unlock();
        if (symbols.known_locked(build_id)) return error.AlreadyKnown;
        const room = bytes <= symbols.uploads_bytes_max - symbols.uploads_bytes_used;
        const slot = (if (room) symbols.claims.add(build_id) else null) orelse {
            log.warn("binary refused: the server is receiving too much at once", .{
                .path = path,
                .kib = log_file.kib(bytes),
                .uploads_kib = log_file.kib(symbols.uploads_bytes_used),
                .uploads_kib_max = log_file.kib(symbols.uploads_bytes_max),
                .uploads = symbols.claims.count(),
                .uploads_max = uploads_max,
            });
            return error.UploadsFull;
        };
        symbols.uploads_bytes_used += bytes;
        return .{ .slot = slot, .bytes = bytes };
    }

    /// Gives back the claim and the bytes of an upload that did not finish.
    fn claim_drop(symbols: *Symbols, ticket: Ticket) void {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        symbols.claims.remove(ticket.slot);
        symbols.uploads_release(ticket.bytes);
    }

    /// Queues a whole binary for the builder; its bytes stay reserved until its table is
    /// built. Takes `received`, whatever it returns.
    fn queue(symbols: *Symbols, ticket: ?Ticket, received: Received) error{QueueFull}!void {
        var owned = received;
        owned.reserved = if (ticket) |held| held.bytes else 0;
        symbols.lock.lock();
        defer symbols.lock.unlock();
        if (ticket) |held| symbols.claims.remove(held.slot);
        if (symbols.known_locked(owned.id)) {
            symbols.received_free(&owned); // Another run sent it first.
            return;
        }
        symbols.builds.push(owned) catch |err| {
            log.warn("binary dropped: too many waiting for their symbol table", .{
                .path = owned.path,
                .waiting_max = builder.Queue.items_max,
            });
            symbols.received_free(&owned);
            return err;
        };
        symbols.builds_changed.broadcast();
    }

    fn received_free(symbols: *Symbols, received: *Received) void {
        symbols.uploads_release(received.reserved);
        received.deinit(symbols.gpa);
    }

    fn uploads_release(symbols: *Symbols, bytes: u64) void {
        assert(bytes <= symbols.uploads_bytes_used);
        symbols.uploads_bytes_used -= bytes;
    }

    /// Builds the queued tables one at a time, without the lock, until the layer stops.
    fn builder_main(symbols: *Symbols) void {
        symbols.lock.lock();
        defer symbols.lock.unlock();
        while (true) {
            while (symbols.builds.count == 0 and !symbols.builds_stopping) {
                symbols.builds_changed.wait(&symbols.lock);
            }
            if (symbols.builds_stopping) return;

            var received = symbols.builds.pop().?;
            symbols.building = received.id;
            symbols.lock.unlock();
            const built = received.build(symbols.gpa);
            symbols.lock.lock();

            symbols.built_keep(&received, built);
            symbols.building = &.{};
            symbols.received_free(&received);
            symbols.builds_changed.broadcast();
        }
    }

    fn built_keep(symbols: *Symbols, received: *const Received, built: anyerror!SymbolTable) void {
        const functions = if (built) |table| table.count else |_| 0;
        const kib = if (built) |table| log_file.kib(table.bytes()) else |_| 0;
        const kept = if (built) |table|
            symbols.binaries.put(symbols.gpa, received.id, table)
        else |err|
            err;
        if (kept) |_| {
            log.debug("symbol table ready", .{
                .path = received.path,
                .functions = functions,
                .kib = kib,
            });
        } else |err| {
            symbols.builds_failed += 1;
            // Too big now is too big next time: no run needs to send it again.
            if (err == error.TooLarge) symbols.refused.add_over_oldest(received.id);
            log.warn("no symbol table: its frames will stay unnamed", .{
                .path = received.path,
                .kib = kib,
                .cause = err,
            });
        }
    }
};

/// The binaries of one agent run, as they arrive: one at a time, each claimed so no other run
/// sends it meanwhile. Not shared between threads: one per run.
pub const Receiver = struct {
    symbols: *Symbols,
    upload: Upload,
    ticket: ?Ticket,

    pub fn init(symbols: *Symbols) Receiver {
        return .{
            .symbols = symbols,
            .upload = Upload.init(symbols.upload_bytes_max),
            .ticket = null,
        };
    }

    /// Drops a binary still arriving.
    pub fn deinit(receiver: *Receiver) void {
        receiver.abort();
        receiver.upload.deinit(receiver.symbols.gpa);
        receiver.* = undefined;
    }

    /// One of the run's binary events, and the answer to give the agent. A failure drops that
    /// binary only (`unwanted` stops it), never the run.
    pub fn take(receiver: *Receiver, event: protocol.RunEvent) protocol.Answer {
        switch (event) {
            .binary_offer => |offer| {
                return if (receiver.symbols.known(offer.build_id)) .unwanted else .wanted;
            },
            .binary_begin => |header| receiver.begin(header) catch |err| return receiver.drop(err),
            .binary_chunk => |*part| receiver.chunk(part) catch |err| return receiver.drop(err),
            .binary_end => receiver.end() catch |err| return receiver.drop(err),
            .binary_abort => {
                if (receiver.upload.receiving) {
                    const path = receiver.upload.path;
                    log.debug("binary not received: the agent stopped", .{ .path = path });
                }
                receiver.abort();
            },
            .report, .stopped => {},
        }
        return .none;
    }

    /// Claims the binary and its bytes, then gets ready for its chunks. `AlreadyKnown` when
    /// another run started sending it since this one was offered it.
    fn begin(receiver: *Receiver, header: *const protocol.binary.Header) !void {
        if (receiver.ticket != null) {
            log.warn("binary refused: the last one never ended", .{ .path = header.path });
            return error.OutOfOrder;
        }
        const bytes = upload_file.bytes_of(header) catch std.math.maxInt(u64);
        if (bytes > receiver.upload.bytes_max) {
            log.warn("binary refused: too big to receive", .{
                .path = header.path,
                .kib = log_file.kib(bytes),
                .kib_max = log_file.kib(receiver.upload.bytes_max),
            });
            return error.TooLarge;
        }
        const symbols = receiver.symbols;
        receiver.ticket = symbols.claim(header.build_id, header.path, bytes) catch |err| {
            if (err == error.AlreadyKnown) log.debug("binary already on its way", .{
                .path = header.path,
            });
            return err;
        };
        errdefer receiver.abort();
        try receiver.upload.begin(symbols.gpa, header);
        log.debug("binary arriving", .{ .path = header.path, .kib = log_file.kib(bytes) });
    }

    fn chunk(receiver: *Receiver, part: *const protocol.binary.Chunk) !void {
        try receiver.upload.chunk(receiver.symbols.gpa, part);
    }

    /// Hands the binary to the builder: the run does not wait for its table.
    fn end(receiver: *Receiver) !void {
        const ticket = receiver.ticket orelse return error.OutOfOrder;
        const received = receiver.upload.end(receiver.symbols.gpa) catch |err| {
            receiver.abort();
            return err;
        };
        receiver.ticket = null;
        // Logged before the hand-over: the builder frees `received`.
        log.debug("binary received", .{ .path = received.path, .kib = log_file.kib(ticket.bytes) });
        try receiver.symbols.queue(ticket, received);
    }

    fn drop(receiver: *Receiver, err: anyerror) protocol.Answer {
        // A refused begin said why already.
        const said = err == error.AlreadyKnown or err == error.TooLarge or
            err == error.OutOfOrder;
        if (!said) log.warn("binary not received: dropped", .{ .cause = err });
        receiver.abort();
        return .unwanted;
    }

    fn abort(receiver: *Receiver) void {
        receiver.upload.abort(receiver.symbols.gpa);
        const ticket = receiver.ticket orelse return;
        receiver.symbols.claim_drop(ticket);
        receiver.ticket = null;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const elf = @import("shared").elf;

test {
    _ = builder;
    _ = upload_file;
    _ = id_set;
    _ = @import("symbols/binaries.zig");
    _ = @import("symbols/symbol_table.zig");
}

/// The symtab and strtab of one function, `function`, at address 0x401100 .. 0x401140.
fn symbols_one(function: *const [4]u8) struct { [24]u8, [6]u8 } {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    return .{ sym, ("\x00" ++ function ++ "\x00").* };
}

/// File offset 0x1000 is address 0x401000: the function is at file offset 0x1100.
const segments_test = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};

/// A table of one function, for the tests of the layers above.
pub fn table_one_testing(gpa: std.mem.Allocator, function: *const [4]u8) !SymbolTable {
    const sym, const strtab = symbols_one(function);
    const input = Input{ .segments = &segments_test, .symtab = &sym, .strtab = &strtab };
    return SymbolTable.init(gpa, input);
}

/// The same function as a binary handed over whole.
fn received_one(gpa: std.mem.Allocator, id: []const u8, function: *const [4]u8) !Received {
    const sym, const strtab = symbols_one(function);
    var starts = std.EnumArray(protocol.binary.Section, usize).initFill(0);
    var sizes = std.EnumArray(protocol.binary.Section, usize).initFill(0);
    starts.set(.strtab, sym.len);
    sizes.set(.symtab, sym.len);
    sizes.set(.strtab, strtab.len);
    return .{
        .id = try gpa.dupe(u8, id),
        .path = try gpa.dupe(u8, "/bin/app"),
        .segments = try gpa.dupe(elf.Segment, &segments_test),
        .data = try std.mem.concat(gpa, u8, &.{ &sym, &strtab }),
        .starts = starts,
        .sizes = sizes,
    };
}

fn header_test(build_id: []const u8, strtab_bytes: u64) protocol.binary.Header {
    var sizes = std.EnumArray(protocol.binary.Section, u64).initFill(0);
    sizes.set(.strtab, strtab_bytes);
    return .{ .build_id = build_id, .path = "/test", .segments = &.{}, .sizes = sizes };
}

test "a received binary is known at once, and named once the builder is done" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{});
    defer symbols.deinit();

    try symbols.queue(null, try received_one(testing.allocator, "aa", "work"));
    try testing.expect(symbols.known("aa"));
    // The same binary from another run is dropped.
    try symbols.queue(null, try received_one(testing.allocator, "aa", "else"));

    symbols.wait();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const names = arena.allocator();
    try testing.expectEqualStrings("work", (try symbols.name(names, "aa", 0x1100)).?);
    try testing.expectEqual(@as(?[]const u8, null), try symbols.name(names, "aa", 0x9000));
    const stats = symbols.stats();
    try testing.expectEqual(@as(usize, 1), stats.binaries);
    try testing.expectEqual(@as(usize, 0), stats.builds_pending);
    try testing.expectEqual(@as(u64, 0), stats.builds_failed);
}

test "a table too big to keep is counted, refused for later, and the layer goes on" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{ .binaries_bytes_max = 8 });
    defer symbols.deinit();

    try symbols.queue(null, try received_one(testing.allocator, "aa", "work"));
    symbols.wait();
    try testing.expectEqual(@as(u64, 1), symbols.stats().builds_failed);
    try testing.expect(symbols.known("aa")); // Refused: not to be sent again.
    try testing.expectEqual(@as(usize, 0), symbols.stats().binaries);
}

test "binaries still queued when the layer stops are freed" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{});
    for (0..8) |index| {
        var id: [2]u8 = .{ 'a', @intCast('a' + index) };
        try symbols.queue(null, try received_one(testing.allocator, &id, "work"));
    }
    symbols.deinit(); // The testing allocator would report a leak.
}

test "uploads share one budget, held from the claim until the table is built" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{ .uploads_bytes_max = 100 });
    defer symbols.deinit();

    const first = try symbols.claim("aa", "/a", 60);
    try testing.expectError(error.UploadsFull, symbols.claim("bb", "/b", 41));
    try testing.expectError(error.AlreadyKnown, symbols.claim("aa", "/a", 1));
    const second = try symbols.claim("bb", "/b", 40);
    try testing.expectEqual(@as(u64, 100), symbols.stats().uploads_bytes);

    // A drop gives its bytes back at once; a queued binary, once its table is built.
    symbols.claim_drop(second);
    try testing.expectEqual(@as(u64, 60), symbols.stats().uploads_bytes);
    try testing.expect(!symbols.known("bb"));
    try symbols.queue(first, try received_one(testing.allocator, "aa", "work"));
    symbols.wait();
    try testing.expectEqual(@as(u64, 0), symbols.stats().uploads_bytes);
}

test "a table the windows use outlives one that nothing uses" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{ .binaries_max = 2 });
    defer symbols.deinit();
    const gpa = testing.allocator;
    try symbols.binaries.put(gpa, "aa", try table_one_testing(gpa, "work"));
    try symbols.binaries.put(gpa, "bb", try table_one_testing(gpa, "rest"));

    // A window needs "aa": now "bb" is the least recently used.
    const regions = [_]protocol.Region{.{
        .start = 0x7000,
        .end = 0x8000,
        .offset = 0x1000,
        .inode = 1,
        .path = "/bin/app",
        .build_id = "aa",
    }};
    symbols.used(&regions);
    try symbols.binaries.put(gpa, "cc", try table_one_testing(gpa, "more"));
    try testing.expect(symbols.known("aa"));
    try testing.expect(!symbols.known("bb"));
}

test "a receiver answers offers, and turns a binary that arrives into a known one" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{});
    defer symbols.deinit();
    var receiver = Receiver.init(&symbols);
    defer receiver.deinit();

    const offer = protocol.RunEvent{ .binary_offer = .{ .build_id = "some-id", .path = "/test" } };
    try testing.expectEqual(protocol.Answer.wanted, receiver.take(offer));
    try testing.expectEqual(protocol.Answer.none, receiver.take(.{
        .binary_begin = &header_test("some-id", 0),
    }));
    // Claimed while it arrives: no other run may send it.
    try testing.expectEqual(protocol.Answer.unwanted, receiver.take(offer));
    try testing.expectEqual(protocol.Answer.none, receiver.take(.binary_end));
    try testing.expect(receiver.ticket == null);
    try testing.expect(symbols.known("some-id"));

    // A chunk that does not fit its header drops the binary, and says so.
    _ = receiver.take(.{ .binary_begin = &header_test("other-id", 0) });
    const chunk = protocol.binary.Chunk{ .section = .symtab, .offset = 0, .bytes = "abc" };
    try testing.expectEqual(protocol.Answer.unwanted, receiver.take(.{ .binary_chunk = chunk }));
    try testing.expect(!symbols.known("other-id"));
}

test "an aborted binary is dropped, and the next one arrives whole" {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, .{});
    defer symbols.deinit();
    var receiver = Receiver.init(&symbols);
    defer receiver.deinit();

    _ = receiver.take(.{ .binary_begin = &header_test("first", 4) });
    const half = protocol.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "ab" };
    _ = receiver.take(.{ .binary_chunk = half });
    _ = receiver.take(.binary_abort);
    try testing.expect(!receiver.upload.receiving);
    _ = receiver.take(.binary_abort); // Nothing in flight: nothing to do.

    _ = receiver.take(.{ .binary_begin = &header_test("second", 4) });
    const whole = protocol.binary.Chunk{ .section = .strtab, .offset = 0, .bytes = "abcd" };
    try testing.expectEqual(protocol.Answer.none, receiver.take(.{ .binary_chunk = whole }));
    try testing.expectEqual(protocol.Answer.none, receiver.take(.binary_end));
    try testing.expect(!symbols.known("first"));
    try testing.expect(symbols.known("second"));
}
