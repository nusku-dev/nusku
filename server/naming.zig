//! The naming layer: a target's windows turned into a profile. Each address is placed in its
//! region's file, named with the symbols layer, and equal call paths are merged. An address
//! whose table is missing keeps its address and module: a frame loses its name, nothing worse.
//! Stands on windows and symbols.
//!   regions.zig, normalize.zig  where an address is in its file
//!   resolve.zig                 one window's stacks, named
//!   lookup.zig                  a cache of names in front of the symbols
//!   merge.zig                   equal call paths, one stack

const std = @import("std");
const assert = std.debug.assert;
const windows_layer = @import("windows.zig");
const symbols_layer = @import("symbols.zig");
const resolve = @import("naming/resolve.zig");
const merge = @import("naming/merge.zig");
const Lookup = @import("naming/lookup.zig").Lookup;

pub const Frame = struct {
    /// As the agent reported it.
    address: u64,
    kernel: bool,
    /// Null when it could not be named.
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    /// The path of the binary it is in.
    module: ?[]const u8 = null,
};

pub const SymbolStack = struct {
    samples: u64,
    /// Innermost frame first, kernel frames before user frames.
    frames: []const Frame,
    complete: bool,
};

pub const Profile = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    /// Lost over the target's life, too big to keep: their samples are not in `samples_lost`.
    windows_rejected: u64,
    /// Most samples first.
    stacks: []const SymbolStack,
};

/// The windows, named and merged, in `arena`.
pub fn profile(
    arena: std.mem.Allocator,
    copied: windows_layer.Copied,
    symbols: *symbols_layer.Symbols,
) !Profile {
    var stacks_count: usize = 0;
    for (copied.windows) |window| stacks_count += window.stacks.len;
    const stacks = try arena.alloc(SymbolStack, stacks_count);

    // On the heap: its cache is large.
    const lookup = try arena.create(Lookup);
    lookup.* = .{ .symbols = symbols };
    var result = Profile{
        .sample_hz = 0,
        .samples = 0,
        .samples_lost = 0,
        .windows_rejected = copied.rejected,
        .stacks = &.{},
    };
    var filled: usize = 0;
    for (copied.windows) |*window| {
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
    _ = @import("naming/regions.zig");
    _ = @import("naming/normalize.zig");
    _ = resolve;
    _ = merge;
    _ = @import("naming/lookup.zig");
}
