const builder = @import("builder.zig");
const info = @import("info.zig");
pub const dwarf_load = @import("loader.zig");

pub const Sections = builder.Sections;
pub const Location = info.Location;
pub const depth_max = info.depth_max;
pub const DebugInfo = info.DebugInfo;
pub const build = builder.build;
