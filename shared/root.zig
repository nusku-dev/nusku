//! Code every module uses: the protocol between the agent and the server, and reading files.

pub const protocol = @import("protocol/protocol.zig");
pub const elf = @import("elf.zig");
pub const directory = @import("directory.zig");
const file = @import("file.zig");

pub const File = file.File;
pub const FileError = file.OpenError || file.ReadError;

test {
    _ = protocol;
    _ = elf;
    _ = file;
    _ = directory;
}
