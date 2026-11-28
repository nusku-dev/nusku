//! The unwind tables as the kernel program reads them.

/// All rows in one map value: the verifier bounds every index by this.
pub const rows_max: u32 = 1 << 18;
pub const row_search_steps_max: u32 = 19;

pub const modules_max: u32 = 256;

pub const mappings_max: u32 = 512;
pub const mapping_search_steps_max: u32 = 10;

pub const processes_max: u32 = 256;

pub const module_none: u32 = 0xffff_ffff;

pub const CfaType = enum(u8) {
    none = 0,
    unsupported = 1,
    rsp = 2,
    rbp = 3,
    plt = 4,
    end = 5,
    go_sched = 6,
    go_vdso = 7,
};

pub const RbpType = enum(u8) {
    same = 0,
    saved = 1,
};

pub const Row = extern struct {
    pc: u32,
    cfa_offset: i32,
    cfa_type: u8,
    rbp_type: u8,
    rbp_offset: i16,
};

pub const GoOffsets = extern struct {
    known: u16 = 0,
    g_m: u16 = 0,
    g_sched: u16 = 0,
    m_g0: u16 = 0,
    m_curg: u16 = 0,
    m_vdso_sp: u16 = 0,
    m_vdso_pc: u16 = 0,
    gobuf_sp: u16 = 0,
    gobuf_pc: u16 = 0,
    gobuf_bp: u16 = 0,
    reserved: u32 = 0,
};

pub const Module = extern struct {
    base: u64,
    row_start: u32,
    row_count: u32,
    end: u32,
    reserved: u32 = 0,
    go: GoOffsets = .{},
};

pub const Mapping = extern struct {
    start: u64,
    end: u64,
    bias: u64,
    module: u32,
    reserved: u32 = 0,
};

pub const ProcessEntry = extern struct {
    count: u32,
    dropped: u32,
    mappings: [mappings_max]Mapping,
};

comptime {
    if (@sizeOf(Row) != 12) @compileError("Row must be 12 bytes");
    if (@sizeOf(GoOffsets) != 24) @compileError("GoOffsets must be 24 bytes");
    if (@sizeOf(Module) != 48) @compileError("Module must be 48 bytes");
    if (@sizeOf(Mapping) != 32) @compileError("Mapping must be 32 bytes");
    if (@sizeOf(ProcessEntry) != 8 + mappings_max * 32) @compileError("ProcessEntry size");

    if ((1 << row_search_steps_max) <= rows_max) @compileError("too few row search steps");
    if ((1 << mapping_search_steps_max) <= mappings_max) {
        @compileError("too few mapping search steps");
    }
    if (rows_max > 0xffff_ffff) @compileError("rows_max must fit in u32");
    if (modules_max >= module_none) @compileError("module_none must not be a module index");
}
