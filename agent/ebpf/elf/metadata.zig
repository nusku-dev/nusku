const utils = @import("utils.zig");

const Error = utils.Error;
const readInt = utils.readInt;

pub const Symbol = struct {
    /// Index of the section the symbol lives in.
    section: usize,
    /// Offset of the symbol inside that section.
    value: usize,
    size: usize,
};

pub const MapDef = struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,

    pub fn init(bytes: []const u8, symbol: Symbol) Error!MapDef {
        return .{
            .map_type = try readInt(u32, bytes, symbol.value),
            .key_size = try readInt(u32, bytes, symbol.value + 4),
            .value_size = try readInt(u32, bytes, symbol.value + 8),
            .max_entries = try readInt(u32, bytes, symbol.value + 12),
        };
    }
};
