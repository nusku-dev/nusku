//! The symbols layer: the target's binaries, offered once per build ID so the server can name
//! the addresses in them. `regions_see` queues the new ones, and each `step` gives one event:
//! an offer, which `want` answers, or a part of a binary being sent. Stands on os, elf and
//! target.
//!   binary.zig          a binary as it is sent: its header and the sections that name things
//!   transfer.zig        one binary on its way, a part per step
//!   vdso_symbols.zig    names for the vDSO's functions, which only its jump stubs have
//!   kernel_symbols.zig  the kernel's symbols, from /proc/kallsyms

const std = @import("std");
const assert = std.debug.assert;
const target = @import("../target/target.zig");
const Region = target.Region;
const binary_file = @import("binary.zig");
const kernel_symbols = @import("kernel_symbols.zig");
const KernelIdentity = target.KernelIdentity;
const Transfer = @import("transfer.zig").Transfer;
const log = @import("../log.zig").agent;

/// Build IDs remembered. Four times the unwind modules, like the registry: many mapped files
/// never matter.
pub const binaries_max = 256;
/// Binaries waiting for their turn. Reports find new ones now and then, not all at once.
pub const pending_max = 16;
/// PATH_MAX without the terminating zero.
pub const path_bytes_max = 4096;
/// Bytes in one chunk.
pub const chunk_bytes = 256 * 1024;

/// A build ID, held by value.
const Id = struct {
    len: u8,
    bytes: [target.build_id_bytes_max]u8,

    fn from(slice_from: []const u8) Id {
        assert(slice_from.len > 0 and slice_from.len <= target.build_id_bytes_max);
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

pub const Event = union(enum) {
    /// A binary to send, if `want(true)` answers before the next `step`.
    offer: Offered,
    begin: *const binary_file.Header,
    /// Its bytes are valid until the next `step`.
    chunk: binary_file.Chunk,
    end,
    /// The binary begun will not end: reading it failed.
    abort,
};

pub const Offered = @import("shared").protocol.binary.Offer;

pub const Symbols = struct {
    /// False: every call is a no-op.
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
    vdso_image: ?*const target.VdsoImage,
    /// Who the running kernel is: its symbols are offered once, before the first binary.
    kernel: KernelIdentity,
    kernel_offered: bool,
    /// Reading the kernel's symbols, on a thread of its own: their transfer starts once it is
    /// done and no binary waits. In `kernel_arena`.
    kernel_reading: ?*kernel_symbols.Background,
    /// Holds the kernel's symbols while they are read and sent, apart from `arena`, which each
    /// binary's transfer resets. Freed once they are sent: a few MiB, not kept for the run.
    kernel_arena: std.heap.ArenaAllocator,
    /// Whether `current` is the kernel's transfer, whose memory is `kernel_arena`.
    current_is_kernel: bool,
    /// The kernel's identity for this boot: `kernel_id[0..kernel_id_len]`.
    kernel_id: [kernel_symbols.id_bytes_max]u8,
    kernel_id_len: usize,

    /// `stop` was called: only the transfer in flight goes on.
    stopping: bool,
    /// What was offered and waits for `want`.
    asked: ?enum { region, kernel },
    /// The region offered, by value: it left the queue.
    asked_region: Candidate,
    /// `want`'s answer. No answer is no.
    answer: bool,

    /// The transfer in flight, if any. One at a time.
    current: ?Transfer,
    /// Holds the header of `current`; reset when the next transfer starts.
    arena: std.heap.ArenaAllocator,
    chunk_buffer: []u8,
    /// Scratch for checking a file's build ID: `target.build_id_prefix_size` bytes.
    prefix: []u8,

    /// `vdso_image` and what `kernel` points into must outlive the offer.
    pub fn init(
        symbols: *Symbols,
        gpa: std.mem.Allocator,
        enabled: bool,
        pid: u32,
        vdso_image: ?*const target.VdsoImage,
        kernel: KernelIdentity,
    ) !void {
        symbols.* = .{
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
            .kernel_reading = null,
            .kernel_arena = .init(gpa),
            .current_is_kernel = false,
            .kernel_id = undefined,
            .kernel_id_len = 0,
            .stopping = false,
            .asked = null,
            .asked_region = undefined,
            .answer = false,
            .current = null,
            .arena = .init(gpa),
            .chunk_buffer = &.{},
            .prefix = &.{},
        };
        if (!enabled) return;

        symbols.seen = try gpa.alloc(Id, binaries_max);
        errdefer gpa.free(symbols.seen);
        symbols.pending = try gpa.alloc(Candidate, pending_max);
        errdefer gpa.free(symbols.pending);
        symbols.chunk_buffer = try gpa.alloc(u8, chunk_bytes);
        errdefer gpa.free(symbols.chunk_buffer);
        symbols.prefix = try gpa.alloc(u8, target.build_id_prefix_size);
    }

    pub fn deinit(symbols: *Symbols, gpa: std.mem.Allocator) void {
        if (symbols.current) |*transfer| transfer.deinit();
        if (symbols.kernel_reading) |reading| reading.deinit();
        symbols.kernel_arena.deinit();
        symbols.arena.deinit();
        gpa.free(symbols.prefix);
        gpa.free(symbols.chunk_buffer);
        gpa.free(symbols.pending);
        gpa.free(symbols.seen);
        symbols.* = undefined;
    }

    /// Looks at the regions of a new report for binaries not offered yet, and queues them.
    pub fn regions_see(symbols: *Symbols, regions: []const Region) void {
        if (!symbols.enabled) return;
        assert(symbols.seen_count <= binaries_max);
        assert(symbols.pending_count <= pending_max);

        for (regions) |*region| {
            const id = region.build_id orelse continue;
            if (id.len == 0 or id.len > target.build_id_bytes_max) continue;
            if (region.path.len == 0 or region.path.len > path_bytes_max) continue;
            if (region.path[0] != '/' and !std.mem.eql(u8, region.path, target.vdso_path)) continue;
            if (symbols.seen_has(id)) continue;
            // Not marked as seen: the next report queues it.
            if (symbols.pending_count == pending_max) continue;
            if (symbols.seen_count == binaries_max) {
                if (!symbols.seen_full_logged) {
                    symbols.seen_full_logged = true;
                    log.warn("too many binaries to offer to the server", .{ .max = binaries_max });
                }
                continue;
            }

            symbols.seen[symbols.seen_count] = Id.from(id);
            symbols.seen_count += 1;
            symbols.pending_push(region);
        }
    }

    /// One event, or null when there is nothing to do now: the caller tries again later. The
    /// kernel is offered first, so its symbols are read on their thread while the binaries are
    /// offered and sent; they are sent once read, when no binary waits.
    pub fn step(symbols: *Symbols) ?Event {
        if (!symbols.enabled) return null;
        if (symbols.stopping) {
            const transfer = &(symbols.current orelse return null);
            return symbols.transfer_step(transfer);
        }
        if (symbols.asked != null) symbols.asked_take();
        if (symbols.current) |*transfer| return symbols.transfer_step(transfer);
        if (!symbols.kernel_offered) {
            symbols.kernel_offered = true;
            if (symbols.kernel_ask()) |event| return event;
        }
        if (symbols.pending_count > 0) return symbols.region_ask();
        const reading = symbols.kernel_reading orelse return null;
        if (!reading.finished()) return null;
        symbols.kernel_finish();
        const transfer = &(symbols.current orelse return null);
        return symbols.transfer_step(transfer);
    }

    /// Answers the last `.offer`. During a transfer, false drops it: the caller had to.
    pub fn want(symbols: *Symbols, wanted: bool) void {
        if (symbols.asked != null) {
            symbols.answer = wanted;
            return;
        }
        if (!wanted and symbols.current != null) symbols.current_end();
    }

    /// The run ends: nothing more is offered or read. A binary already begun goes on to its end
    /// through `step`, so a short run keeps the names it was being sent; one bounded transfer.
    pub fn stop(symbols: *Symbols) void {
        symbols.stopping = true;
        if (symbols.kernel_reading) |reading| {
            reading.deinit();
            symbols.kernel_reading = null;
        }
        symbols.pending_count = 0;
        symbols.asked = null;
        const transfer = &(symbols.current orelse return);
        if (!transfer.begun()) symbols.current_end();
    }

    fn transfer_step(symbols: *Symbols, transfer: *Transfer) ?Event {
        const part = transfer.step(symbols.chunk_buffer) catch |err| {
            log.warn("sending a binary failed: dropped", .{
                .pid = symbols.pid,
                .path = transfer.binary.header.path,
                .cause = err,
            });
            const begun = transfer.begun();
            symbols.current_end();
            return if (begun) .abort else null;
        };
        switch (part) {
            .begin => |header| return .{ .begin = header },
            .chunk => |chunk| return .{ .chunk = chunk },
            .end => {
                symbols.current_end();
                return .end;
            },
        }
    }

    fn current_end(symbols: *Symbols) void {
        symbols.current.?.deinit();
        symbols.current = null;
        if (symbols.current_is_kernel) {
            symbols.current_is_kernel = false;
            _ = symbols.kernel_arena.reset(.free_all);
        }
    }

    fn region_ask(symbols: *Symbols) Event {
        symbols.asked_region = symbols.pending_at(0).*;
        symbols.pending_drop();
        symbols.asked = .region;
        const region = symbols.asked_region.region();
        return .{ .offer = .{ .build_id = region.build_id.?, .path = region.path } };
    }

    fn kernel_ask(symbols: *Symbols) ?Event {
        const kernel = &symbols.kernel;
        const found = kernel_symbols.id(&symbols.kernel_id, kernel.build_id, kernel.text_address);
        const id = found orelse {
            log.debug("kernel symbols not offered: the kernel does not say who it is", .{
                .build_id_found = kernel.build_id != null,
                .text_address_found = kernel.text_address != null,
            });
            return null;
        };
        symbols.kernel_id_len = id.len;
        symbols.asked = .kernel;
        return .{ .offer = .{ .build_id = id, .path = kernel_symbols.path } };
    }

    /// Acts on the answer to the offer: opens the binary, or starts reading the kernel's.
    fn asked_take(symbols: *Symbols) void {
        const asked = symbols.asked.?;
        const wanted = symbols.answer;
        symbols.asked = null;
        symbols.answer = false;
        if (!wanted) return;
        switch (asked) {
            .region => symbols.region_open(),
            .kernel => symbols.kernel_start(),
        }
    }

    fn region_open(symbols: *Symbols) void {
        const region = symbols.asked_region.region();
        symbols.arena_reset();
        const arena = symbols.arena.allocator();
        const image = symbols.vdso_image;
        const opened = binary_file.open(arena, symbols.pid, &region, symbols.prefix, image);
        const binary = opened catch |err| {
            log.debug("binary not sent: it cannot be opened", .{
                .path = region.path,
                .cause = err,
            });
            return;
        };
        symbols.current = Transfer.init(binary);
    }

    fn kernel_start(symbols: *Symbols) void {
        _ = symbols.kernel_arena.reset(.free_all);
        const arena = symbols.kernel_arena.allocator();
        const started = kernel_symbols.Background.start(arena, symbols.kernel.text_address.?);
        symbols.kernel_reading = (started catch null) orelse {
            log.debug("kernel symbols not sent: kallsyms cannot be read", .{});
            return;
        };
    }

    /// The kernel's symbols, read: they become the transfer.
    fn kernel_finish(symbols: *Symbols) void {
        const reading = symbols.kernel_reading.?;
        defer {
            reading.deinit();
            symbols.kernel_reading = null;
        }
        // Only root reads the addresses: anyone else, zeros.
        const found = reading.symbols() catch |err| {
            log.debug("kernel symbols not sent: kallsyms could not be read", .{ .cause = err });
            return;
        };
        const names = found orelse {
            log.debug("kernel symbols not sent: their addresses are hidden", .{});
            return;
        };
        const id = symbols.kernel_id[0..symbols.kernel_id_len];
        const binary = binary_file.kernel_binary(symbols.kernel_arena.allocator(), id, &names) catch
            return;
        log.debug("kernel symbols read", .{
            .release = symbols.kernel.release,
            .symbols = names.count,
            .names_kib = names.strtab.len / 1024,
        });
        symbols.current = Transfer.init(binary);
        symbols.current_is_kernel = true;
    }

    /// Nothing waits, nothing is in flight.
    fn idle(symbols: *const Symbols) bool {
        return symbols.pending_count == 0 and symbols.asked == null and symbols.current == null and
            symbols.kernel_reading == null and symbols.kernel_offered;
    }

    /// Frees the last binary's memory, keeping it for the next.
    fn arena_reset(symbols: *Symbols) void {
        _ = symbols.arena.reset(.retain_capacity);
    }

    fn seen_has(symbols: *const Symbols, id: []const u8) bool {
        for (symbols.seen[0..symbols.seen_count]) |*known| {
            if (std.mem.eql(u8, known.slice(), id)) return true;
        }
        return false;
    }

    fn pending_push(symbols: *Symbols, region: *const Region) void {
        assert(symbols.pending_count < pending_max);
        assert(region.path.len <= path_bytes_max);

        const index = (symbols.pending_head + symbols.pending_count) % pending_max;
        const candidate = &symbols.pending[index];
        candidate.id = Id.from(region.build_id.?);
        candidate.start = region.start;
        candidate.end = region.end;
        candidate.offset = region.offset;
        candidate.inode = region.inode;
        candidate.path_len = @intCast(region.path.len);
        @memcpy(candidate.path[0..region.path.len], region.path);
        symbols.pending_count += 1;
    }

    /// The `index`-th waiting candidate, 0 being the next to send.
    fn pending_at(symbols: *const Symbols, index: u32) *const Candidate {
        assert(index < symbols.pending_count);
        return &symbols.pending[(symbols.pending_head + index) % pending_max];
    }

    fn pending_drop(symbols: *Symbols) void {
        assert(symbols.pending_count > 0);
        symbols.pending_head = (symbols.pending_head + 1) % pending_max;
        symbols.pending_count -= 1;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = binary_file;
    _ = kernel_symbols;
    _ = @import("transfer.zig");
    _ = @import("vdso_symbols.zig");
}
const os = @import("../os/os.zig");
const process = @import("../os/os.zig").process;

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

fn symbols_test(enabled: bool, image: ?*const target.VdsoImage) !Symbols {
    var symbols: Symbols = undefined;
    try symbols.init(testing.allocator, enabled, process.current_pid(), image, .{});
    return symbols;
}

test "a disabled offer does nothing and costs nothing" {
    var symbols = try symbols_test(false, null);
    defer symbols.deinit(testing.allocator);
    symbols.regions_see(&.{region_test("/bin/a", "\x01")});
    try testing.expectEqual(@as(u32, 0), symbols.pending_count);
    try testing.expectEqual(@as(u32, 0), symbols.seen_count);
}

test "each file with a build ID is queued once, in order, and the rest is ignored" {
    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);

    const regions = [_]Region{
        region_test("/bin/a", "\x0a"),
        region_test("/bin/a", "\x0a"), // another mapping of the same file
        region_test("/lib/b.so", "\x0b"),
        region_test("", "\x0c"), // anonymous memory
        region_test("[vdso]", "\x0d"), // the vDSO: no file, but the agent holds its image
        region_test("/bin/no_id", null),
    };
    symbols.regions_see(&regions);
    try testing.expectEqual(@as(u32, 3), symbols.pending_count);
    try testing.expectEqualStrings("/bin/a", symbols.pending_at(0).region().path);
    try testing.expectEqualSlices(u8, "\x0b", symbols.pending_at(1).region().build_id.?);
    try testing.expectEqualStrings("[vdso]", symbols.pending_at(2).region().path);

    // The next report sees the same regions and one new library.
    symbols.regions_see(&(regions ++ [_]Region{region_test("/lib/c.so", "\x0e")}));
    try testing.expectEqual(@as(u32, 4), symbols.pending_count);
    try testing.expectEqualStrings("/lib/c.so", symbols.pending_at(3).region().path);
}

test "a full queue leaves the rest for the next report" {
    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);

    var ids: [pending_max + 4][1]u8 = undefined;
    var regions: [pending_max + 4]Region = undefined;
    for (&regions, &ids, 0..) |*region, *id, index| {
        id[0] = @intCast(index);
        region.* = region_test("/bin/x", id);
    }
    symbols.regions_see(&regions);
    try testing.expectEqual(@as(u32, pending_max), symbols.pending_count);

    // The sender took them all; the four that did not fit were not marked as seen.
    symbols.pending_count = 0;
    symbols.pending_head = 0;
    symbols.regions_see(&regions);
    try testing.expectEqual(@as(u32, 4), symbols.pending_count);
    try testing.expectEqual(@as(u8, pending_max), symbols.pending_at(0).region().build_id.?[0]);
}

test "more build IDs than the table holds are not offered, and the run goes on" {
    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);

    for (0..binaries_max + 10) |index| {
        const id: u32 = @intCast(index);
        symbols.regions_see(&.{region_test("/bin/x", std.mem.asBytes(&id))});
        symbols.pending_count = 0; // The sender keeps up.
        symbols.pending_head = 0;
    }
    try testing.expectEqual(@as(u32, binaries_max), symbols.seen_count);
    try testing.expect(symbols.seen_full_logged);
    // The same binaries again, at the next report: still not offered, nothing grows.
    const id: u32 = binaries_max + 1;
    symbols.regions_see(&.{region_test("/bin/x", std.mem.asBytes(&id))});
    try testing.expectEqual(@as(u32, 0), symbols.pending_count);
    try testing.expectEqual(@as(u32, binaries_max), symbols.seen_count);
}

/// What a server does with the events: wants what it does not know, and counts the rest.
const Consumer = struct {
    known: []const []const u8 = &.{},
    /// Drops a transfer at its first chunk, as a server whose upload failed.
    drop_at_chunk: bool = false,
    offers: u32 = 0,
    begins: u32 = 0,
    chunks: u32 = 0,
    ends: u32 = 0,
    aborts: u32 = 0,
    bytes: u64 = 0,
    announced: u64 = 0,

    fn take(consumer: *Consumer, symbols: *Symbols, event: Event) void {
        switch (event) {
            .offer => |offered| {
                consumer.offers += 1;
                symbols.want(!consumer.knows(offered.build_id));
            },
            .begin => |header| {
                consumer.begins += 1;
                for (std.enums.values(binary_file.Section)) |section| {
                    consumer.announced += header.sizes.get(section);
                }
            },
            .chunk => |chunk| {
                consumer.chunks += 1;
                consumer.bytes += chunk.bytes.len;
                if (consumer.drop_at_chunk) symbols.want(false);
            },
            .end => consumer.ends += 1,
            .abort => consumer.aborts += 1,
        }
    }

    fn knows(consumer: *const Consumer, id: []const u8) bool {
        for (consumer.known) |known| {
            if (std.mem.eql(u8, known, id)) return true;
        }
        return false;
    }

    /// Steps until the offer is idle; returns the steps it took.
    fn drain(consumer: *Consumer, symbols: *Symbols) !u32 {
        var steps: u32 = 0;
        while (!symbols.idle()) : (steps += 1) {
            if (steps > 100_000) return error.NeverIdle;
            const event = symbols.step() orelse continue;
            consumer.take(symbols, event);
        }
        return steps;
    }
};

/// The build ID of /bin/sh, or null when it has none. `prefix` holds it.
fn sh_id(prefix: []u8) !?[]const u8 {
    var file = try target.file_open(process.current_pid(), &region_test("/bin/sh", null), prefix);
    defer file.deinit();
    const read = try file.read_at(prefix, 0);
    return target.build_id_of(prefix[0..read]);
}

test "each binary is offered; a known one is skipped, a wanted one sent whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prefix: [target.build_id_prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;
    var own = try target.Target.init(testing.allocator, os.process.current_pid());
    defer own.deinit(testing.allocator);
    const image = own.vdso_image() orelse return error.SkipZigTest;
    const vdso_id = image.build_id orelse return error.SkipZigTest;

    var symbols = try symbols_test(true, image);
    defer symbols.deinit(testing.allocator);
    var vdso_region = region_test(target.vdso_path, vdso_id);
    vdso_region.end = vdso_region.start + image.bytes.len;
    symbols.regions_see(&.{ vdso_region, region_test("/bin/sh", shell) });

    // The server has the shell; it wants the vDSO.
    const known = [_][]const u8{shell};
    var consumer = Consumer{ .known = &known };
    _ = try consumer.drain(&symbols);
    try testing.expectEqual(@as(u32, 2), consumer.offers);
    try testing.expectEqual(@as(u32, 1), consumer.begins);
    try testing.expectEqual(@as(u32, 1), consumer.ends);
    try testing.expectEqual(@as(u32, 0), consumer.aborts);
    try testing.expectEqual(consumer.announced, consumer.bytes);
}

test "an offer not answered is not sent, and a transfer dropped midway stops" {
    var prefix: [target.build_id_prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);
    symbols.regions_see(&.{region_test("/bin/sh", shell)});
    try testing.expect(symbols.step().? == .offer);
    try testing.expectEqual(@as(?Event, null), symbols.step()); // No answer: no.
    try testing.expect(symbols.current == null);

    var again = try symbols_test(true, null);
    defer again.deinit(testing.allocator);
    again.regions_see(&.{region_test("/bin/sh", shell)});
    var consumer = Consumer{ .drop_at_chunk = true };
    _ = try consumer.drain(&again);
    try testing.expectEqual(@as(u32, 1), consumer.chunks);
    try testing.expectEqual(@as(u32, 0), consumer.ends);
    try testing.expectEqual(@as(u32, 0), consumer.aborts); // The consumer dropped it itself.
}

test "a run that stops during a transfer finishes it, and starts nothing new" {
    var prefix: [target.build_id_prefix_size]u8 = undefined;
    const shell = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);
    symbols.regions_see(&.{region_test("/bin/sh", shell)});
    try testing.expect(symbols.step().? == .offer);
    symbols.want(true);
    try testing.expect(symbols.step().? == .begin);

    symbols.regions_see(&.{region_test("/bin/ls", "\x01\x02")}); // Waiting: never offered.
    symbols.stop();
    var consumer = Consumer{ .begins = 1 };
    while (symbols.step()) |event| consumer.take(&symbols, event);
    try testing.expectEqual(@as(u32, 1), consumer.ends);
    try testing.expectEqual(@as(u32, 0), consumer.offers);
    try testing.expect(symbols.current == null);
    symbols.stop(); // Again: nothing more.
    try testing.expectEqual(@as(?Event, null), symbols.step());
}

test "a binary that cannot be opened is dropped, not retried" {
    var symbols = try symbols_test(true, null);
    defer symbols.deinit(testing.allocator);
    symbols.regions_see(&.{region_test("/no/such/file", "\x01\x02")});

    var consumer = Consumer{};
    _ = try consumer.drain(&symbols);
    try testing.expectEqual(@as(u32, 1), consumer.offers);
    try testing.expectEqual(@as(u32, 0), consumer.begins);

    symbols.regions_see(&.{region_test("/no/such/file", "\x01\x02")});
    try testing.expectEqual(@as(u32, 0), symbols.pending_count);
}

test "the kernel is offered first and read on its thread, while a binary is sent" {
    var prefix: [target.build_id_prefix_size]u8 = undefined;
    const id = (try sh_id(&prefix)) orelse return error.SkipZigTest;

    var symbols: Symbols = undefined;
    const kernel = KernelIdentity{ .build_id = "kk", .text_address = 0xffffffff81000000 };
    try symbols.init(testing.allocator, true, process.current_pid(), null, kernel);
    defer symbols.deinit(testing.allocator);
    symbols.regions_see(&.{region_test("/bin/sh", id)});

    const kernel_offer = symbols.step().?;
    try testing.expectEqualStrings(kernel_symbols.path, kernel_offer.offer.path);
    symbols.want(true);
    // Its reading starts with the next step, which offers the binary meanwhile.
    const binary_offer = symbols.step().?;
    try testing.expectEqualStrings("/bin/sh", binary_offer.offer.path);
    try testing.expect(symbols.kernel_reading != null);
    symbols.want(true);

    // The binary is sent whole first; the kernel's symbols, once read, after it.
    var consumer = Consumer{};
    var steps: u32 = 0;
    while (!symbols.idle()) : (steps += 1) {
        if (steps > 100_000) return error.NeverIdle;
        const event = symbols.step() orelse {
            os.timer.sleep_ms(1); // The thread is reading.
            continue;
        };
        if (event == .begin and consumer.ends == 0) {
            try testing.expectEqualStrings("/bin/sh", event.begin.path);
        }
        consumer.take(&symbols, event);
    }
    // As root the kernel's symbols are then sent; without, they were hidden, and are not.
    const root = std.os.linux.geteuid() == 0;
    try testing.expectEqual(@as(u32, if (root) 2 else 1), consumer.ends);
}

test "a run that stops while the kernel is read stops the reading" {
    var symbols: Symbols = undefined;
    const kernel = KernelIdentity{ .build_id = "kk", .text_address = 0xffffffff81000000 };
    try symbols.init(testing.allocator, true, process.current_pid(), null, kernel);
    defer symbols.deinit(testing.allocator);

    try testing.expect(symbols.step().? == .offer);
    symbols.want(true);
    try testing.expectEqual(@as(?Event, null), symbols.step());
    try testing.expect(symbols.kernel_reading != null);
    const started_ns = os.timer.monotonic_ns();
    symbols.stop();
    try testing.expect(symbols.kernel_reading == null);
    // At most one step of the thread: well under the 0.8 s of the whole read.
    try testing.expect(os.timer.monotonic_ns() - started_ns < 300 * std.time.ns_per_ms);
}
