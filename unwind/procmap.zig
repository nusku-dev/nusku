//! What the BPF program needs to turn a pc into table rows: for one process, its executable
//! mappings sorted by address. Each says which module's table applies and the bias that turns a
//! runtime address into a file address. `find` is written the way the BPF program must do it.
const std = @import("std");
const registry = @import("registry.zig");

pub const max_mappings = 128;
/// Binary search over 128 entries needs at most 8 steps.
pub const max_search_steps = 8;
/// A mapping of executable code that has no table: unwind with frame pointers.
pub const no_module: u32 = 0xffff_ffff;

pub const Mapping = extern struct {
    start: u64,
    end: u64,
    /// Runtime address = file address + bias.
    bias: u64,
    module: u32,
    reserved: u32 = 0,
};

pub const ProcessEntry = extern struct {
    count: u32,
    /// How many executable mappings did not fit.
    dropped: u32,
    mappings: [max_mappings]Mapping,
};

comptime {
    std.debug.assert(@sizeOf(Mapping) == 32);
    std.debug.assert(@sizeOf(ProcessEntry) == 8 + max_mappings * 32);
}

pub const Input = struct { start: u64, end: u64, offset: u64, outcome: registry.Outcome };

pub const BuildError = error{Unsorted};

/// `inputs` must be sorted by address, without overlaps or empty ranges, as /proc/PID/maps is.
pub fn build(inputs: []const Input) BuildError!ProcessEntry {
    var entry = std.mem.zeroes(ProcessEntry);
    var previous_end: u64 = 0;
    for (inputs) |in| {
        if (in.end <= in.start or in.start < previous_end) return error.Unsorted;
        previous_end = in.end;
        if (entry.count == max_mappings) {
            entry.dropped += 1;
            continue;
        }
        entry.mappings[entry.count] = switch (in.outcome) {
            .loaded => |l| .{
                .start = in.start,
                .end = in.end,
                .bias = registry.biasOf(l.delta, in.start, in.offset),
                .module = l.id,
            },
            .unavailable => .{ .start = in.start, .end = in.end, .bias = 0, .module = no_module },
        };
        entry.count += 1;
    }
    return entry;
}

/// The mapping that holds `pc`, or null if no executable mapping does.
pub fn find(entry: *const ProcessEntry, pc: u64) ?Mapping {
    var lo: u32 = 0;
    var hi: u32 = @min(entry.count, max_mappings);
    var steps: u32 = 0;
    while (lo < hi and steps < max_search_steps) : (steps += 1) {
        const mid = lo + (hi - lo) / 2;
        if (entry.mappings[mid].start <= pc) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const m = entry.mappings[lo - 1];
    return if (pc < m.end) m else null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn loaded(id: u32, delta: u64) registry.Outcome {
    return .{ .loaded = .{ .id = id, .delta = delta } };
}

test "find: inside a mapping, at its edges, in gaps, and outside all of them" {
    const inputs = [_]Input{
        .{ .start = 0x400000, .end = 0x401000, .offset = 0, .outcome = loaded(0, 0) },
        .{ .start = 0x7f00_0000_0000, .end = 0x7f00_0010_0000, .offset = 0x28000, .outcome = loaded(1, 0x28000) },
        .{ .start = 0x7f00_0020_0000, .end = 0x7f00_0020_2000, .offset = 0, .outcome = .{ .unavailable = .no_unwind_info } },
    };
    const entry = try build(&inputs);
    try testing.expectEqual(@as(u32, 3), entry.count);
    try testing.expectEqual(@as(u32, 0), entry.dropped);

    try testing.expect(find(&entry, 0x3fffff) == null);
    try testing.expectEqual(@as(u32, 0), find(&entry, 0x400000).?.module);
    try testing.expectEqual(@as(u32, 0), find(&entry, 0x400fff).?.module);
    try testing.expect(find(&entry, 0x401000) == null); // the end is exclusive
    try testing.expect(find(&entry, 0x7eff_ffff_ffff) == null);

    const libc = find(&entry, 0x7f00_0000_0000).?;
    try testing.expectEqual(@as(u32, 1), libc.module);
    // The start of the mapping is the file address offset + delta.
    try testing.expectEqual(@as(u64, 0x50000), 0x7f00_0000_0000 -% libc.bias);
    try testing.expectEqual(@as(u32, 1), find(&entry, 0x7f00_000f_ffff).?.module);
    try testing.expect(find(&entry, 0x7f00_0010_0000) == null);
    try testing.expect(find(&entry, 0x7f00_001f_ffff) == null);

    const bare = find(&entry, 0x7f00_0020_0000).?;
    try testing.expectEqual(no_module, bare.module);
    try testing.expectEqual(no_module, find(&entry, 0x7f00_0020_1fff).?.module);
    try testing.expect(find(&entry, 0x7f00_0020_2000) == null);
    try testing.expect(find(&entry, std.math.maxInt(u64)) == null);
}

test "a process with no executable mappings finds nothing" {
    const entry = try build(&.{});
    try testing.expectEqual(@as(u32, 0), entry.count);
    try testing.expect(find(&entry, 0) == null);
    try testing.expect(find(&entry, 0x400000) == null);
}

test "more mappings than fit: the first ones are kept and the rest are counted" {
    var inputs: [200]Input = undefined;
    for (&inputs, 0..) |*in, i| {
        const start: u64 = 0x10000 + @as(u64, i) * 0x2000;
        in.* = .{ .start = start, .end = start + 0x1000, .offset = 0, .outcome = loaded(@intCast(i), 0) };
    }
    const entry = try build(&inputs);
    try testing.expectEqual(@as(u32, max_mappings), entry.count);
    try testing.expectEqual(@as(u32, 72), entry.dropped);
    try testing.expectEqual(@as(u32, 127), find(&entry, 0x10000 + 127 * 0x2000).?.module);
    try testing.expect(find(&entry, 0x10000 + 128 * 0x2000) == null); // the first one that did not fit
}

test "input that is not sorted, overlaps, or has an empty range is refused" {
    const reversed = [_]Input{
        .{ .start = 0x2000, .end = 0x3000, .offset = 0, .outcome = loaded(0, 0) },
        .{ .start = 0x1000, .end = 0x1800, .offset = 0, .outcome = loaded(1, 0) },
    };
    try testing.expectError(error.Unsorted, build(&reversed));

    const overlapping = [_]Input{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0, .outcome = loaded(0, 0) },
        .{ .start = 0x1fff, .end = 0x3000, .offset = 0, .outcome = loaded(1, 0) },
    };
    try testing.expectError(error.Unsorted, build(&overlapping));

    const empty_range = [_]Input{.{ .start = 0x1000, .end = 0x1000, .offset = 0, .outcome = loaded(0, 0) }};
    try testing.expectError(error.Unsorted, build(&empty_range));
}
