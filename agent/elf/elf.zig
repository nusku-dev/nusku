//! The elf layer: reading ELF files, as the unwinder and the symbols both need. A toolbox:
//!   file      loads the headers and the asked-for sections of an ELF file
//!   eh_frame  parses .eh_frame and .debug_frame into their CIEs and FDEs
//! Stands on os only.

pub const file = @import("elf_file.zig");
pub const eh_frame = @import("eh_frame.zig");

test {
    _ = file;
    _ = eh_frame;
}
