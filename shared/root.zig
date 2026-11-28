//! Code every module uses.
const file = @import("file.zig");

pub const protocol = @import("protocol/protocol.zig");
pub const directory = @import("directory.zig");
pub const elf = @import("elf.zig");
pub const dwarf = @import("dwarf/dwarf.zig");

pub const File = file.File;
pub const FileError = file.OpenError || file.ReadError;

test {
    _ = dwarf;
    _ = protocol;
    _ = elf;
    _ = file;
    _ = directory;
}
