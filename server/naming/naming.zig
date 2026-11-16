//! The naming layer: a target's windows turned into a profile.

const std = @import("std");
const assert = std.debug.assert;
const windows_layer = @import("../windows/windows.zig");
const symbols_layer = @import("../symbols/symbols.zig");
const resolve = @import("resolve.zig");
const merge = @import("merge.zig");
const Lookup = @import("lookup.zig").Lookup;

pub const Frame = struct {
    address: u64,
    kernel: bool,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    module: ?[]const u8 = null,
    inlined: bool = false,
};

pub const SymbolStack = struct {
    samples: u64,
    frames: []const Frame,
    complete: bool,
};

pub const Window = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    samples: u64,
    samples_lost: u64,
};

pub const Profile = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    windows_rejected: u64,
    stacks: []const SymbolStack,
    windows: []const Window = &.{},
    names_generation: u64 = 0,
};

pub fn profile(
    arena: std.mem.Allocator,
    copied: windows_layer.Copied,
    symbols: *symbols_layer.Symbols,
) !Profile {
    var stacks_count: usize = 0;
    for (copied.windows) |window| stacks_count += window.stacks.len;
    const names_generation = symbols.stats().generation;
    const stacks = try arena.alloc(SymbolStack, stacks_count);

    const windows = try arena.alloc(Window, copied.windows.len);

    const lookup = try arena.create(Lookup);
    lookup.* = .{ .symbols = symbols };
    var result = Profile{
        .sample_hz = 0,
        .samples = 0,
        .samples_lost = 0,
        .windows_rejected = copied.rejected,
        .stacks = &.{},
        .windows = windows,
        .names_generation = names_generation,
    };
    var filled: usize = 0;
    for (copied.windows, windows) |*window, *summary| {
        summary.* = .{
            .start_unix_ns = window.start_unix_ns,
            .duration_ns = window.duration_ns,
            .samples = window.samples,
            .samples_lost = window.samples_lost,
        };
        const resolved = try resolve.window_resolve(arena, lookup, window);
        @memcpy(stacks[filled..][0..resolved.len], resolved);
        filled += resolved.len;
        result.samples += window.samples;
        result.samples_lost += window.samples_lost;
        result.sample_hz = window.sample_hz;
    }
    assert(filled == stacks.len);
    result.stacks = merge.stacks_merge(stacks);
    return result;
}

test {
    _ = @import("regions.zig");
    _ = @import("normalize.zig");
    _ = resolve;
    _ = merge;
    _ = @import("lookup.zig");
}
