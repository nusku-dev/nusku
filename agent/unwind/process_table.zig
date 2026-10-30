//! What the kernel program needs to turn a pc into table rows: for one process, its executable
//! mappings sorted by address. Each says which module's table applies, and the bias that turns
//! a runtime address into a file address. `find` searches the way the kernel program must.

const std = @import("std");
const assert = std.debug.assert;
const registry = @import("registry.zig");
const unwind_wire = @import("../bpf/kernel/shared/unwind_wire.zig");

pub const Mapping = unwind_wire.Mapping;
pub const ProcessEntry = unwind_wire.ProcessEntry;
pub const mappings_max = unwind_wire.mappings_max;
pub const module_none = unwind_wire.module_none;

pub const Input = struct { start: u64, end: u64, offset: u64, outcome: registry.Outcome };

/// Fills `entry` from `inputs`, which must be sorted by address, without overlaps or empty
/// ranges, as /proc/<pid>/maps is.
pub fn build(entry: *ProcessEntry, inputs: []const Input) error{Unsorted}!void {
    var builder = Builder.init(entry);
    for (inputs) |input| try builder.add(input);
    assert(entry.count + entry.dropped == inputs.len);
}

/// Fills an entry one mapping at a time, so a process with any number of mappings needs no
/// buffer. The first `mappings_max` mappings are kept and the rest counted: the kernel's search
/// is bounded by that size.
pub const Builder = struct {
    entry: *ProcessEntry,
    previous_end: u64,

    pub fn init(entry: *ProcessEntry) Builder {
        entry.* = std.mem.zeroes(ProcessEntry);
        return .{ .entry = entry, .previous_end = 0 };
    }

    pub fn add(builder: *Builder, input: Input) error{Unsorted}!void {
        if (input.end <= input.start) return error.Unsorted;
        if (input.start < builder.previous_end) return error.Unsorted;
        builder.previous_end = input.end;

        const entry = builder.entry;
        assert(entry.count <= mappings_max);
        if (entry.count == mappings_max) {
            entry.dropped += 1;
            return;
        }
        entry.mappings[entry.count] = switch (input.outcome) {
            .loaded => |loaded| .{
                .start = input.start,
                .end = input.end,
                .bias = registry.bias_of(loaded.delta, input.start, input.offset),
                .module = loaded.id,
            },
            .unavailable => .{
                .start = input.start,
                .end = input.end,
                .bias = 0,
                .module = module_none,
            },
        };
        entry.count += 1;
    }
};

/// The mapping that holds `pc`, or null if no executable mapping does.
pub fn find(entry: *const ProcessEntry, pc: u64) ?Mapping {
    assert(entry.count <= mappings_max);
    var low: u32 = 0;
    var high: u32 = entry.count;
    var steps: u32 = 0;
    while (low < high and steps < unwind_wire.mapping_search_steps_max) : (steps += 1) {
        const middle = low + @divFloor(high - low, 2);
        if (entry.mappings[middle].start <= pc) low = middle + 1 else high = middle;
    }
    // The search converged: running out of steps first would give a wrong mapping.
    assert(low == high);
    if (low == 0) return null;
    const mapping = entry.mappings[low - 1];
    return if (pc < mapping.end) mapping else null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn outcome_loaded(id: u32, delta: u64) registry.Outcome {
    return .{ .loaded = .{ .id = id, .delta = delta } };
}

test "find: inside a mapping, at its edges, in gaps, and outside all of them" {
    const inputs = [_]Input{
        .{ .start = 0x400000, .end = 0x401000, .offset = 0, .outcome = outcome_loaded(0, 0) },
        .{
            .start = 0x7f00_0000_0000,
            .end = 0x7f00_0010_0000,
            .offset = 0x28000,
            .outcome = outcome_loaded(1, 0x28000),
        },
        .{
            .start = 0x7f00_0020_0000,
            .end = 0x7f00_0020_2000,
            .offset = 0,
            .outcome = .{ .unavailable = .no_unwind_info },
        },
    };
    var entry: ProcessEntry = undefined;
    try build(&entry, &inputs);
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
    try testing.expectEqual(module_none, bare.module);
    try testing.expectEqual(module_none, find(&entry, 0x7f00_0020_1fff).?.module);
    try testing.expect(find(&entry, 0x7f00_0020_2000) == null);
    try testing.expect(find(&entry, std.math.maxInt(u64)) == null);
}

test "a process with no executable mappings finds nothing" {
    var entry: ProcessEntry = undefined;
    try build(&entry, &.{});
    try testing.expectEqual(@as(u32, 0), entry.count);
    try testing.expect(find(&entry, 0) == null);
    try testing.expect(find(&entry, 0x400000) == null);
}

test "more mappings than fit: the first ones are kept and the rest are counted" {
    const dropped = 72;
    var inputs: [mappings_max + dropped]Input = undefined;
    for (&inputs, 0..) |*input, i| {
        const start: u64 = 0x10000 + @as(u64, i) * 0x2000;
        input.* = .{
            .start = start,
            .end = start + 0x1000,
            .offset = 0,
            .outcome = outcome_loaded(@intCast(i), 0),
        };
    }
    var entry: ProcessEntry = undefined;
    try build(&entry, &inputs);
    try testing.expectEqual(@as(u32, mappings_max), entry.count);
    try testing.expectEqual(@as(u32, dropped), entry.dropped);
    // The last one that fit, and the first one that did not.
    const last_kept = mappings_max - 1;
    try testing.expectEqual(last_kept, find(&entry, 0x10000 + last_kept * 0x2000).?.module);
    try testing.expect(find(&entry, 0x10000 + @as(u64, mappings_max) * 0x2000) == null);
}

test "input that is not sorted, overlaps, or has an empty range is refused" {
    const reversed = [_]Input{
        .{ .start = 0x2000, .end = 0x3000, .offset = 0, .outcome = outcome_loaded(0, 0) },
        .{ .start = 0x1000, .end = 0x1800, .offset = 0, .outcome = outcome_loaded(1, 0) },
    };
    var entry: ProcessEntry = undefined;
    try testing.expectError(error.Unsorted, build(&entry, &reversed));

    const overlapping = [_]Input{
        .{ .start = 0x1000, .end = 0x2000, .offset = 0, .outcome = outcome_loaded(0, 0) },
        .{ .start = 0x1fff, .end = 0x3000, .offset = 0, .outcome = outcome_loaded(1, 0) },
    };
    try testing.expectError(error.Unsorted, build(&entry, &overlapping));

    const empty_range = [_]Input{
        .{ .start = 0x1000, .end = 0x1000, .offset = 0, .outcome = outcome_loaded(0, 0) },
    };
    try testing.expectError(error.Unsorted, build(&entry, &empty_range));
}
