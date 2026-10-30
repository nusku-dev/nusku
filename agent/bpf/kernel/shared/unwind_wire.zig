//! The unwind tables as the kernel program reads them from its maps.
//!
//! This file is compiled twice: into the kernel program (bpfel, freestanding) and into the
//! agent. Both sides must agree on every byte, so it holds only extern structs and constants,
//! and it does not import std: the BPF target has no operating system to build std against.

/// All rows of all modules live in one array map value: 2^18 rows of 12 bytes is 3 MiB.
/// One value (instead of one map entry per row) lets the program reach any row with a single
/// lookup, and the verifier can bound every index by this constant.
pub const rows_max: u32 = 1 << 18;
/// A binary search over n rows needs floor(log2(n)) + 1 steps.
pub const row_search_steps_max: u32 = 19;

/// Distinct binaries (executables and libraries) with a table, over the whole run.
pub const modules_max: u32 = 256;

/// Executable mappings remembered for one process. More are counted in `ProcessEntry.dropped`.
/// Most libraries map their code once, so this is about the number of libraries: a JVM maps
/// about a hundred, a browser two or three hundred.
pub const mappings_max: u32 = 512;
pub const mapping_search_steps_max: u32 = 10;

/// Processes with an entry in the process map. The map is preallocated: 256 entries of 16 KiB
/// is 4 MiB of kernel memory. The agent profiles one target today.
pub const processes_max: u32 = 256;

/// The module of a mapping that has executable code but no table: frame pointers unwind it.
pub const module_none: u32 = 0xffff_ffff;

/// How a row computes the Canonical Frame Address, the stack pointer of the caller.
pub const CfaType = enum(u8) {
    /// No function covers the range: a gap between functions.
    none = 0,
    /// The rules of the range cannot be written in this format.
    unsupported = 1,
    /// CFA = rsp + cfa_offset.
    rsp = 2,
    /// CFA = rbp + cfa_offset.
    rbp = 3,
    /// A PLT stub: CFA = rsp + 8, plus 8 more when (rip % 16) >= cfa_offset.
    plt = 4,
    /// The return address is undefined: this is the outermost frame.
    end = 5,
};

/// How a row recovers the caller's rbp.
pub const RbpType = enum(u8) {
    /// rbp holds the same value in the caller.
    same = 0,
    /// rbp is saved in memory at CFA + rbp_offset.
    saved = 1,
};

/// The rules that hold from `pc` up to the `pc` of the next row. The return address is always
/// at CFA - 8, so a row does not store it.
pub const Row = extern struct {
    /// Where the range starts, relative to `Module.base`.
    pc: u32,
    cfa_offset: i32,
    /// A `CfaType`, kept as a byte because the kernel reads it from untrusted memory.
    cfa_type: u8,
    /// A `RbpType`, kept as a byte for the same reason.
    rbp_type: u8,
    rbp_offset: i16,
};

/// Where the rows of one module are in the row array.
pub const Module = extern struct {
    /// The file address every `Row.pc` of the module is relative to.
    base: u64,
    row_start: u32,
    row_count: u32,
    /// One past the last covered address, relative to `base`.
    end: u32,
    reserved: u32 = 0,
};

/// One executable mapping of a process.
pub const Mapping = extern struct {
    start: u64,
    end: u64,
    /// Runtime address = file address + bias.
    bias: u64,
    /// An index into the module map, or `module_none`.
    module: u32,
    reserved: u32 = 0,
};

/// The executable mappings of one process, sorted by `start`, without overlaps.
pub const ProcessEntry = extern struct {
    count: u32,
    /// How many executable mappings did not fit in `mappings`.
    dropped: u32,
    mappings: [mappings_max]Mapping,
};

comptime {
    // The wire format: a change here is a change on both sides of the boundary.
    if (@sizeOf(Row) != 12) @compileError("Row must be 12 bytes");
    if (@sizeOf(Module) != 24) @compileError("Module must be 24 bytes");
    if (@sizeOf(Mapping) != 32) @compileError("Mapping must be 32 bytes");
    if (@sizeOf(ProcessEntry) != 8 + mappings_max * 32) @compileError("ProcessEntry size");

    // The bounded searches must converge before they run out of steps.
    if ((1 << row_search_steps_max) <= rows_max) @compileError("too few row search steps");
    if ((1 << mapping_search_steps_max) <= mappings_max) {
        @compileError("too few mapping search steps");
    }
    // An index into the row array must fit in the u32 fields that hold it.
    if (rows_max > 0xffff_ffff) @compileError("rows_max must fit in u32");
    if (modules_max >= module_none) @compileError("module_none must not be a module index");
}
