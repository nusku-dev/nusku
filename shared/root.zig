//! Code both the agent and the server use: the protocol between them, and reading files.

pub const protocol = @import("protocol.zig");
pub const elf = @import("elf.zig");
const file = @import("file.zig");

pub const File = file.File;
pub const FileError = file.OpenError || file.ReadError;

test {
    _ = protocol;
    _ = elf;
    _ = file;
}
