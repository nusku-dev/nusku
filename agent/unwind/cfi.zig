//! The rules of DWARF call frame information: how to reach the caller's frame from any address
//! of a function. x86-64 only.

/// rax, rdx, rcx, rbx, rsi, rdi, rbp, rsp, r8 to r15, then 16, the return address. Rules for
/// other registers are read and ignored: they never matter for finding the caller.
pub const num_regs = 17;
pub const reg_rbp = 6;
pub const reg_rsp = 7;
pub const reg_ra = 16;

const reg_names = [num_regs][]const u8{
    "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
    "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15",
    "ra",
};

/// What happened to a register when the function was entered, seen from its caller.
pub const Rule = union(enum) {
    /// Nothing says anything about it.
    unspecified,
    /// The caller's value is lost. For the return address this marks the outermost frame.
    undef,
    /// The caller's value is the register's current value.
    same,
    /// Saved in memory at CFA + n.
    offset: i64,
    /// The caller's value is CFA + n, and nothing is stored.
    val_offset: i64,
    /// Held in another register.
    register: u64,
    /// Saved in memory at the address this DWARF expression computes. Points into the section.
    expression: []const u8,
    /// The caller's value is what this DWARF expression computes. Points into the section.
    val_expression: []const u8,
};

/// The Canonical Frame Address:
/// the value the stack pointer had in the caller before the call.
pub const Cfa = union(enum) {
    unset,
    register: struct {
        reg: u64,
        offset: i64,
    },
    /// Points into the section. Compilers write this for PLT stubs.
    expression: []const u8,
};

pub const Row = struct {
    cfa: Cfa = .unset,
    rules: [num_regs]Rule = [_]Rule{.unspecified} ** num_regs,
};
