//! Code both the agent and the server use: reading ELF files, and reading files.

pub const elf = @import("elf.zig");
const file = @import("file.zig");

pub const File = file.File;
pub const FileError = file.OpenError || file.ReadError;

test {
    _ = elf;
    _ = file;
}
