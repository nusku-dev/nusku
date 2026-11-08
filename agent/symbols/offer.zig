//! Offers the target's binaries to the server once per build ID: `regions_see` queues the new
//! ones, and `pump`, once per loop round, sends a few chunks. A stream that stops early ends in
//! `binary_abort`.

const std = @import("std");
const assert = std.debug.assert;
const build_id = @import("../target/build_id.zig");
const vdso = @import("../target/vdso.zig");
const Region = @import("../target/regions.zig").Region;
const binary_file = @import("binary.zig");
const kernel_symbols = @import("kernel_symbols.zig");
const KernelIdentity = @import("../target/kernel.zig").Identity;
const Transfer = @import("transfer.zig").Transfer;
const log = @import("../log.zig").agent;

/// Build IDs remembered. Four times the unwind modules, like the registry: many mapped files
/// never matter.
pub const binaries_max = 256;
/// Binaries waiting for their turn. Reports find new ones now and then, not all at once.
pub const pending_max = 16;
/// PATH_MAX without the terminating zero.
pub const path_bytes_max = 4096;
/// Bytes in one chunk, and chunks sent per loop round: at most 1 MiB per tick of 100 ms.
pub const chunk_bytes = 256 * 1024;
pub const chunks_per_round = 4;
/// Bytes of /proc/kallsyms read per loop round: about 12 ms of the kernel's time, and some 5 s
/// for all of it. Read in one go, it would hold up the loop for more than half a second.
pub const kallsyms_bytes_per_round = 256 * 1024;

/// A build ID, held by value.
const Id = struct {
    len: u8,
    bytes: [build_id.id_bytes_max]u8,

    fn from(slice_from: []const u8) Id {
        assert(slice_from.len > 0 and slice_from.len <= build_id.id_bytes_max);
        var id = Id{ .len = @intCast(slice_from.len), .bytes = undefined };
        @memcpy(id.bytes[0..slice_from.len], slice_from);
        return id;
    }

    fn slice(id: *const Id) []const u8 {
        return id.bytes[0..id.len];
    }
};

/// A region waiting to be offered, held by value: the report it came from will be gone.
const Candidate = struct {
    id: Id,
    start: u64,
    end: u64,
    offset: u64,
    inode: u64,
    path_len: u16,
    path: [path_bytes_max]u8,

    /// The region, pointing into this candidate: valid while the candidate stays where it is.
    fn region(candidate: *const Candidate) Region {
        return .{
            .start = candidate.start,
            .end = candidate.end,
            .offset = candidate.offset,
            .inode = candidate.inode,
            .path = candidate.path[0..candidate.path_len],
            .build_id = candidate.id.slice(),
        };
    }
};

pub const Offer = struct {
    /// False when the context has no binary hooks: every call is then a no-op.
    enabled: bool,
    pid: u32,
    /// Build IDs asked about in this run: `[0, seen_count)`.
    seen: []Id,
    seen_count: u32,
    /// A queue of capacity `pending_max`: `pending_count` entries from `pending_head` on.
    pending: []Candidate,
    pending_head: u32,
    pending_count: u32,
    /// `seen` filled up, and the binaries found after that are not offered. Said once.
    seen_full_logged: bool,
    /// The agent's own vDSO image, if it has one: what a [vdso] region is sent from.
    vdso_image: ?*const vdso.Image,
    /// Who the running kernel is: its symbols are offered once, before the first binary.
    kernel: KernelIdentity,
    kernel_offered: bool,
    /// Reading the kernel's symbols, a piece per round when no binary is being sent; the
    /// kernel's transfer starts when it is done.
    kernel_reader: ?kernel_symbols.Reader,
    /// Holds the kernel's symbols while they are read and sent, apart from `arena`, which each
    /// binary's transfer resets. Freed once they are sent: a few MiB, not kept for the run.
    kernel_arena: std.heap.ArenaAllocator,
    /// Whether `current` is the kernel's transfer, whose memory is `kernel_arena`.
    current_is_kernel: bool,

    /// The transfer in flight, if any. One at a time.
    current: ?Transfer,
    /// Holds the header of `current`; reset when the next transfer starts.
    arena: std.heap.ArenaAllocator,
    chunk_buffer: []u8,
    /// Scratch for checking a file's build ID: `build_id.prefix_size` bytes.
    prefix: []u8,

    /// `vdso_image` and what `kernel` points into must outlive the offer.
    pub fn init(
        offer: *Offer,
        gpa: std.mem.Allocator,
        enabled: bool,
        pid: u32,
        vdso_image: ?*const vdso.Image,
        kernel: KernelIdentity,
    ) !void {
        offer.* = .{
            .enabled = enabled,
            .pid = pid,
            .seen = &.{},
            .seen_count = 0,
            .pending = &.{},
            .pending_head = 0,
            .pending_count = 0,
            .seen_full_logged = false,
            .vdso_image = vdso_image,
            .kernel = kernel,
            .kernel_offered = false,
            .kernel_reader = null,
            .kernel_arena = .init(gpa),
            .current_is_kernel = false,
            .current = null,
            .arena = .init(gpa),
            .chunk_buffer = &.{},
            .prefix = &.{},
        };
        if (!enabled) return;

        offer.seen = try gpa.alloc(Id, binaries_max);
        errdefer gpa.free(offer.seen);
        offer.pending = try gpa.alloc(Candidate, pending_max);
        errdefer gpa.free(offer.pending);
        offer.chunk_buffer = try gpa.alloc(u8, chunk_bytes);
        errdefer gpa.free(offer.chunk_buffer);
        offer.prefix = try gpa.alloc(u8, build_id.prefix_size);
    }

    /// Call `stop` first if a transfer may be in flight, so the sink hears that it ends.
    pub fn deinit(offer: *Offer, gpa: std.mem.Allocator) void {
        if (offer.current) |*transfer| transfer.deinit();
        if (offer.kernel_reader) |*reader| reader.deinit();
        offer.kernel_arena.deinit();
        offer.arena.deinit();
        gpa.free(offer.prefix);
        gpa.free(offer.chunk_buffer);
        gpa.free(offer.pending);
        gpa.free(offer.seen);
        offer.* = undefined;
    }

    /// Looks at the regions of a new report for binaries not offered yet, and queues them.
    pub fn regions_see(offer: *Offer, regions: []const Region) void {
        if (!offer.enabled) return;
        assert(offer.seen_count <= binaries_max);
        assert(offer.pending_count <= pending_max);

        for (regions) |*region| {
            const id = region.build_id orelse continue;
            if (id.len == 0 or id.len > build_id.id_bytes_max) continue;
            if (region.path.len == 0 or region.path.len > path_bytes_max) continue;
            if (region.path[0] != '/' and !std.mem.eql(u8, region.path, vdso.path)) continue;
            if (offer.seen_has(id)) continue;
            // Not marked as seen: the next report queues it.
            if (offer.pending_count == pending_max) continue;
            if (offer.seen_count == binaries_max) {
                if (!offer.seen_full_logged) {
                    offer.seen_full_logged = true;
                    log.warn("too many binaries to offer to the server", .{ .max = binaries_max });
                }
                continue;
            }

            offer.seen[offer.seen_count] = Id.from(id);
            offer.seen_count += 1;
            offer.pending_push(region);
        }
    }

    /// Does a bounded amount of sending: with nothing in flight it deals with the next waiting
    /// binary (the server knows it, or it is opened and starts); with a transfer in flight it
    /// sends at most `chunks_per_round` chunks. Called once per loop round. Problems with a
    /// binary or with the sink drop that binary and are logged; they never stop the profile.
    pub fn pump(offer: *Offer, sink: anytype) void {
        if (!offer.enabled) return;

        if (offer.current == null) offer.next_start(sink);
        // With no binary to send, a piece of the kernel's symbols is read instead.
        const transfer = if (offer.current) |*current| current else {
            if (offer.kernel_reader != null) offer.kernel_read();
            return;
        };

        const done = transfer.pump(sink, offer.chunk_buffer, chunks_per_round) catch |err| {
            log.warn("sending a binary failed: dropped", .{
                .pid = offer.pid,
                .path = transfer.binary.header.path,
                .cause = err,
            });
            offer.current_drop(sink);
            return;
        };
        if (done) offer.current_end();
    }

    /// The run ends: a transfer still in flight is aborted, so the sink can drop what it got.
    pub fn stop(offer: *Offer, sink: anytype) void {
        if (!offer.enabled) return;
        if (offer.current != null) offer.current_drop(sink);
        assert(offer.current == null);
    }

    fn current_drop(offer: *Offer, sink: anytype) void {
        const transfer = &offer.current.?;
        if (transfer.begun()) sink.binary_abort();
        offer.current_end();
    }

    fn current_end(offer: *Offer) void {
        offer.current.?.deinit();
        offer.current = null;
        if (offer.current_is_kernel) {
            offer.current_is_kernel = false;
            _ = offer.kernel_arena.reset(.free_all);
        }
    }

    /// Takes the next waiting binary: dropped if the server knows it or it cannot be opened,
    /// otherwise it becomes the transfer in flight.
    fn next_start(offer: *Offer, sink: anytype) void {
        assert(offer.current == null);
        // The binaries first: the target's own code is what a profile is about. The kernel's
        // symbols are read in the rounds with nothing else to send.
        if (offer.pending_count == 0) {
            if (!offer.kernel_offered) {
                offer.kernel_offered = true;
                offer.kernel_start(sink);
            }
            return;
        }

        const region = offer.pending_at(0).region();
        defer offer.pending_drop();

        if (sink.binary_known(region.build_id.?)) return;

        offer.arena_reset();
        const arena = offer.arena.allocator();
        const opened = binary_file.open(arena, offer.pid, &region, offer.prefix, offer.vdso_image);
        const binary = opened catch |err| {
            log.debug("binary not offered: it cannot be opened", .{
                .path = region.path,
                .cause = err,
            });
            return;
        };
        offer.current = Transfer.init(binary);
    }

    /// Starts reading the kernel's symbols, if the server does not have them for this boot.
    fn kernel_start(offer: *Offer, sink: anytype) void {
        var id_buffer: [kernel_symbols.id_bytes_max]u8 = undefined;
        const kernel = &offer.kernel;
        const id = kernel_symbols.id(&id_buffer, kernel.build_id, kernel.text_address) orelse {
            log.debug("kernel symbols not offered: the kernel does not say who it is", .{
                .build_id_found = kernel.build_id != null,
                .text_address_found = kernel.text_address != null,
            });
            return;
        };
        if (sink.binary_known(id)) return;

        _ = offer.kernel_arena.reset(.free_all);
        const arena = offer.kernel_arena.allocator();
        const opened = kernel_symbols.Reader.init(arena, kernel.text_address.?);
        offer.kernel_reader = (opened catch null) orelse {
            log.debug("kernel symbols not offered: kallsyms cannot be read", .{});
            return;
        };
    }

    /// One more piece of kallsyms; at its end, the kernel's symbols become the transfer.
    fn kernel_read(offer: *Offer) void {
        const reader = &offer.kernel_reader.?;
        const done = reader.step(kallsyms_bytes_per_round) catch |err| {
            log.debug("kernel symbols not offered: kallsyms could not be read", .{ .cause = err });
            return offer.kernel_reader_drop();
        };
        if (!done) return;
        defer offer.kernel_reader_drop();

        // Root reads the addresses; anyone else reads zeros, and there is nothing to send.
        const symbols = reader.symbols() orelse {
            log.debug("kernel symbols not offered: their addresses are hidden", .{});
            return;
        };
        var id_buffer: [kernel_symbols.id_bytes_max]u8 = undefined;
        const kernel = &offer.kernel;
        const id = kernel_symbols.id(&id_buffer, kernel.build_id, kernel.text_address).?;
        const binary = binary_file.kernel_binary(offer.kernel_arena.allocator(), id, &symbols) catch
            return;
        log.debug("kernel symbols offered", .{
            .release = kernel.release,
            .symbols = symbols.count,
            .names_kib = symbols.strtab.len / 1024,
        });
        offer.current = Transfer.init(binary);
        offer.current_is_kernel = true;
    }

    fn kernel_reader_drop(offer: *Offer) void {
        offer.kernel_reader.?.deinit();
        offer.kernel_reader = null;
    }

    /// Frees the last binary's memory, keeping it for the next.
    fn arena_reset(offer: *Offer) void {
        _ = offer.arena.reset(.retain_capacity);
    }

    fn seen_has(offer: *const Offer, id: []const u8) bool {
        for (offer.seen[0..offer.seen_count]) |*known| {
            if (std.mem.eql(u8, known.slice(), id)) return true;
        }
        return false;
    }

    fn pending_push(offer: *Offer, region: *const Region) void {
        assert(offer.pending_count < pending_max);
        assert(region.path.len <= path_bytes_max);

        const index = (offer.pending_head + offer.pending_count) % pending_max;
        const candidate = &offer.pending[index];
        candidate.id = Id.from(region.build_id.?);
        candidate.start = region.start;
        candidate.end = region.end;
        candidate.offset = region.offset;
        candidate.inode = region.inode;
        candidate.path_len = @intCast(region.path.len);
        @memcpy(candidate.path[0..region.path.len], region.path);
        offer.pending_count += 1;
    }

    /// The `index`-th waiting candidate, 0 being the next to send.
    fn pending_at(offer: *const Offer, index: u32) *const Candidate {
        assert(index < offer.pending_count);
        return &offer.pending[(offer.pending_head + index) % pending_max];
    }

    fn pending_drop(offer: *Offer) void {
        assert(offer.pending_count > 0);
        offer.pending_head = (offer.pending_head + 1) % pending_max;
        offer.pending_count -= 1;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;
const process = @import("../os/process.zig");
const mapped_file = @import("../target/mapped_file.zig");

fn region_test(path: []const u8, id: ?[]const u8) Region {
    return .{
        .start = 0x1000,
        .end = 0x2000,
        .offset = 0,
        .inode = 1,
        .path = path,
        .build_id = id,
    };
}

fn offer_test(enabled: bool, image: ?*const vdso.Image) !Offer {
    var offer: Offer = undefined;
    try offer.init(testing.allocator, enabled, process.current_pid(), image, .{});
    return offer;
}

test "a disabled offer does nothing and costs nothing" {
    var offer = try offer_test(false, null);
    defer offer.deinit(testing.allocator);
    offer.regions_see(&.{region_test("/bin/a", "\x01")});
    try testing.expectEqual(@as(u32, 0), offer.pending_count);
    try testing.expectEqual(@as(u32, 0), offer.seen_count);
}

test "each file with a build ID is queued once, in order, and the rest is ignored" {
    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);

    const regions = [_]Region{
        region_test("/bin/a", "\x0a"),
        region_test("/bin/a", "\x0a"), // another mapping of the same file
        region_test("/lib/b.so", "\x0b"),
        region_test("", "\x0c"), // anonymous memory
        region_test("[vdso]", "\x0d"), // the vDSO: no file, but the agent holds its image
        region_test("/bin/no_id", null),
    };
    offer.regions_see(&regions);
    try testing.expectEqual(@as(u32, 3), offer.pending_count);
    try testing.expectEqualStrings("/bin/a", offer.pending_at(0).region().path);
    try testing.expectEqualSlices(u8, "\x0b", offer.pending_at(1).region().build_id.?);
    try testing.expectEqualStrings("[vdso]", offer.pending_at(2).region().path);

    // The next report sees the same regions and one new library.
    offer.regions_see(&(regions ++ [_]Region{region_test("/lib/c.so", "\x0e")}));
    try testing.expectEqual(@as(u32, 4), offer.pending_count);
    try testing.expectEqualStrings("/lib/c.so", offer.pending_at(3).region().path);
}

test "a full queue leaves the rest for the next report" {
    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);

    var ids: [pending_max + 4][1]u8 = undefined;
    var regions: [pending_max + 4]Region = undefined;
    for (&regions, &ids, 0..) |*region, *id, index| {
        id[0] = @intCast(index);
        region.* = region_test("/bin/x", id);
    }
    offer.regions_see(&regions);
    try testing.expectEqual(@as(u32, pending_max), offer.pending_count);

    // The sender took them all; the four that did not fit were not marked as seen.
    offer.pending_count = 0;
    offer.pending_head = 0;
    offer.regions_see(&regions);
    try testing.expectEqual(@as(u32, 4), offer.pending_count);
    try testing.expectEqual(@as(u8, pending_max), offer.pending_at(0).region().build_id.?[0]);
}

test "more build IDs than the table holds are not offered, and the run goes on" {
    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);

    for (0..binaries_max + 10) |index| {
        const id: u32 = @intCast(index);
        offer.regions_see(&.{region_test("/bin/x", std.mem.asBytes(&id))});
        offer.pending_count = 0; // The sender keeps up.
        offer.pending_head = 0;
    }
    try testing.expectEqual(@as(u32, binaries_max), offer.seen_count);
    try testing.expect(offer.seen_full_logged);
    // The same binaries again, at the next report: still not offered, nothing grows.
    const id: u32 = binaries_max + 1;
    offer.regions_see(&.{region_test("/bin/x", std.mem.asBytes(&id))});
    try testing.expectEqual(@as(u32, 0), offer.pending_count);
    try testing.expectEqual(@as(u32, binaries_max), offer.seen_count);
}

/// A server that knows some build IDs, counts what it is sent, and can be made to fail.
const Sink = struct {
    known: []const []const u8 = &.{},
    fail_chunk: bool = false,
    asked: u32 = 0,
    begins: u32 = 0,
    chunks: u32 = 0,
    ends: u32 = 0,
    aborts: u32 = 0,
    bytes: u64 = 0,
    announced: u64 = 0,

    pub fn binary_known(sink: *Sink, id: []const u8) bool {
        sink.asked += 1;
        for (sink.known) |known| {
            if (std.mem.eql(u8, known, id)) return true;
        }
        return false;
    }

    pub fn binary_begin(sink: *Sink, header: *const binary_file.Header) !void {
        sink.begins += 1;
        for (std.enums.values(binary_file.Section)) |section| {
            sink.announced += header.sizes.get(section);
        }
    }

    pub fn binary_chunk(sink: *Sink, chunk: *const binary_file.Chunk) !void {
        if (sink.fail_chunk) return error.SinkFailed;
        sink.chunks += 1;
        sink.bytes += chunk.bytes.len;
    }

    pub fn binary_end(sink: *Sink) !void {
        sink.ends += 1;
    }

    pub fn binary_abort(sink: *Sink) void {
        sink.aborts += 1;
    }
};

/// The build ID of /bin/sh, or null when it has none. `prefix` holds it.
fn sh_id(prefix: []u8) !?[]const u8 {
    var file = try mapped_file.open(process.current_pid(), &region_test("/bin/sh", null), prefix);
    defer file.deinit();
    const read = try file.read_at(prefix, 0);
    return build_id.from_prefix(prefix[0..read]);
}

test "pump asks the server, skips what it knows, and streams the rest in bounded rounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prefix: [build_id.prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;
    const image = (try vdso.read(arena.allocator())) orelse return error.SkipZigTest;
    const vdso_id = image.build_id orelse return error.SkipZigTest;

    var offer = try offer_test(true, &image);
    defer offer.deinit(testing.allocator);
    var vdso_region = region_test(vdso.path, vdso_id);
    vdso_region.end = vdso_region.start + image.bytes.len;
    offer.regions_see(&.{ vdso_region, region_test("/bin/sh", shell) });
    try testing.expectEqual(@as(u32, 2), offer.pending_count);

    // The server already has the shell; it wants the vDSO.
    const known = [_][]const u8{shell};
    var sink = Sink{ .known = &known };
    var rounds: u32 = 0;
    while (offer.pending_count > 0 or offer.current != null) : (rounds += 1) {
        const chunks_before = sink.chunks;
        offer.pump(&sink);
        try testing.expect(sink.chunks - chunks_before <= chunks_per_round);
        try testing.expect(rounds < 1000);
    }

    try testing.expectEqual(@as(u32, 2), sink.asked);
    try testing.expectEqual(@as(u32, 1), sink.begins);
    try testing.expectEqual(@as(u32, 1), sink.ends);
    try testing.expectEqual(@as(u32, 0), sink.aborts);
    try testing.expect(sink.chunks >= 1);
    try testing.expectEqual(sink.announced, sink.bytes); // Everything announced arrived.
}

test "a sink that fails drops the binary, and the profile goes on" {
    var prefix: [build_id.prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);
    offer.regions_see(&.{region_test("/bin/sh", shell)});

    var sink = Sink{ .fail_chunk = true };
    var rounds: u32 = 0;
    while (offer.pending_count > 0 or offer.current != null) : (rounds += 1) {
        offer.pump(&sink); // No error comes out.
        try testing.expect(rounds < 1000);
    }
    try testing.expectEqual(@as(u32, 1), sink.begins);
    try testing.expectEqual(@as(u32, 0), sink.ends); // It never completed,
    try testing.expectEqual(@as(u32, 1), sink.aborts); // and the sink was told.
    try testing.expect(offer.current == null);
}

test "a run that stops during a transfer aborts it" {
    var prefix: [build_id.prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);
    offer.regions_see(&.{region_test("/bin/sh", shell)});

    // Opened, and one small chunk sent: the rest is still to come.
    var sink = Sink{};
    offer.next_start(&sink);
    var buffer: [16]u8 = undefined;
    try testing.expect(!try offer.current.?.pump(&sink, &buffer, 1));
    try testing.expectEqual(@as(u32, 1), sink.begins);

    offer.stop(&sink);
    try testing.expectEqual(@as(u32, 1), sink.aborts);
    try testing.expectEqual(@as(u32, 0), sink.ends);
    try testing.expect(offer.current == null);
    offer.stop(&sink); // Nothing in flight: nothing more to say.
    try testing.expectEqual(@as(u32, 1), sink.aborts);
}

test "a binary that cannot be opened is dropped, not retried" {
    var offer = try offer_test(true, null);
    defer offer.deinit(testing.allocator);
    offer.regions_see(&.{region_test("/no/such/file", "\x01\x02")});

    var sink = Sink{};
    offer.pump(&sink);
    try testing.expectEqual(@as(u32, 1), sink.asked);
    try testing.expectEqual(@as(u32, 0), sink.begins);
    try testing.expectEqual(@as(u32, 0), offer.pending_count);
    try testing.expect(offer.current == null);

    // The same regions again: already seen, nothing queued.
    offer.regions_see(&.{region_test("/no/such/file", "\x01\x02")});
    try testing.expectEqual(@as(u32, 0), offer.pending_count);
}

test "the binaries go first; the kernel's symbols are read after, a piece per round" {
    var prefix: [build_id.prefix_size]u8 = undefined;
    const id = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var offer: Offer = undefined;
    const kernel = KernelIdentity{ .build_id = "kk", .text_address = 0xffffffff81000000 };
    try offer.init(testing.allocator, true, process.current_pid(), null, kernel);
    defer offer.deinit(testing.allocator);
    var sink = Sink{};

    offer.regions_see(&.{region_test("/bin/sh", id)});
    // The first round starts the binary, not the kernel.
    offer.pump(&sink);
    try testing.expectEqual(@as(u32, 1), sink.begins);
    try testing.expect(offer.kernel_reader == null);

    var rounds: u32 = 0;
    while (offer.current != null) : (rounds += 1) offer.pump(&sink);
    try testing.expectEqual(@as(u32, 1), sink.ends);

    // Nothing left to send: the kernel's turn. Kallsyms is read over many rounds.
    offer.pump(&sink);
    try testing.expect(offer.kernel_reader != null);
    var reading: u32 = 1;
    while (offer.kernel_reader != null) : (reading += 1) offer.pump(&sink);
    try testing.expect(reading > 3);

    // As root the kernel's symbols are then sent; without, they were hidden and are not.
    if (std.os.linux.geteuid() == 0) {
        try testing.expect(offer.current_is_kernel);
        while (offer.current != null) offer.pump(&sink);
        try testing.expectEqual(@as(u32, 2), sink.ends);
    } else {
        try testing.expect(offer.current == null);
    }
    try testing.expect(offer.kernel_offered);
}
