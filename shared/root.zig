//! Code both the agent and the server use: the protocol between them, and reading files.

pub const protocol = @import("protocol.zig");
pub const elf = @import("elf.zig");
pub const directory = @import("directory.zig");
/// The rule of the layers, checked on the sources: see layers.zig.
pub const layers = @import("layers.zig");
const file = @import("file.zig");

pub const File = file.File;
pub const FileError = file.OpenError || file.ReadError;

test {
    _ = protocol;
    _ = elf;
    _ = file;
    _ = directory;
    _ = layers;
}
