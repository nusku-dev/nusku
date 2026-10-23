//! Reading what compilers leave in a binary about how to walk its stack.
pub const sections = @import("sections.zig");
pub const ehframe = @import("ehframe.zig");
pub const cfi = @import("cfi.zig");
pub const frame = @import("frame.zig");
pub const module = @import("module.zig");
pub const walk = @import("walk.zig");
pub const compact = @import("compact.zig");
pub const tableset = @import("tableset.zig");
pub const registry = @import("registry.zig");
pub const procmap = @import("procmap.zig");
pub const compactwalk = @import("compactwalk.zig");

const dump = @import("dump.zig");

test {
    _ = sections;
    _ = ehframe;
    _ = cfi;
    _ = dump;
    _ = frame;
    _ = module;
    _ = walk;
    _ = compact;
    _ = tableset;
    _ = registry;
    _ = procmap;
    _ = compactwalk;
    _ = @import("real_test.zig");
}
