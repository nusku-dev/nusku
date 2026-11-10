//! The rules of DWARF call frame information.

pub const num_regs = 17;
pub const reg_rbp = 6;
pub const reg_rsp = 7;
pub const reg_ra = 16;

const reg_names = [num_regs][]const u8{
    "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    "ra",
};

pub const Rule = union(enum) {
    unspecified,
    undef,
    same,
    offset: i64,
    val_offset: i64,
    register: u64,
    expression: []const u8,
    val_expression: []const u8,
};

pub const Cfa = union(enum) {
    unset,
    register: struct {
        reg: u64,
        offset: i64,
    },
    expression: []const u8,
};

pub const Row = struct {
    cfa: Cfa = .unset,
    rules: [num_regs]Rule = [_]Rule{.unspecified} ** num_regs,
};
