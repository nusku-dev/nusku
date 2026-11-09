//! Test-only: binaries and symbol tables of one function, for the tests of every layer that
//! names addresses. Not part of the server.

const std = @import("std");
const protocol = @import("shared").protocol;
const elf = @import("shared").elf;
const symbol_table = @import("../symbols/symbol_table.zig");
const Received = @import("../symbols/builder.zig").Received;

const SymbolTable = symbol_table.SymbolTable;

/// File offset 0x1000 is address 0x401000: the function is at file offset 0x1100.
const segments = [_]elf.Segment{.{ .offset = 0x1000, .vaddr = 0x401000, .filesz = 0x1000 }};

/// The symtab and strtab of one function, `function`, at address 0x401100 .. 0x401140.
fn symbols_one(function: *const [4]u8) struct { [24]u8, [6]u8 } {
    var sym: [24]u8 = @splat(0);
    std.mem.writeInt(u32, sym[0..4], 1, .little);
    sym[4] = 0x12; // Global function.
    std.mem.writeInt(u16, sym[6..8], 1, .little);
    std.mem.writeInt(u64, sym[8..16], 0x401100, .little);
    std.mem.writeInt(u64, sym[16..24], 0x40, .little);
    return .{ sym, ("\x00" ++ function ++ "\x00").* };
}

/// A table of one function, at file offset 0x1100.
pub fn table_one(gpa: std.mem.Allocator, function: *const [4]u8) !SymbolTable {
    const sym, const strtab = symbols_one(function);
    const input = symbol_table.Input{ .segments = &segments, .symtab = &sym, .strtab = &strtab };
    return SymbolTable.init(gpa, input);
}

/// The same function as a binary arrived whole, owning its buffers.
pub fn received_one(gpa: std.mem.Allocator, id: []const u8, function: *const [4]u8) !Received {
    const sym, const strtab = symbols_one(function);
    var starts = std.EnumArray(protocol.binary.Section, usize).initFill(0);
    var sizes = std.EnumArray(protocol.binary.Section, usize).initFill(0);
    starts.set(.strtab, sym.len);
    sizes.set(.symtab, sym.len);
    sizes.set(.strtab, strtab.len);
    return .{
        .id = try gpa.dupe(u8, id),
        .path = try gpa.dupe(u8, "/bin/app"),
        .segments = try gpa.dupe(elf.Segment, &segments),
        .data = try std.mem.concat(gpa, u8, &.{ &sym, &strtab }),
        .starts = starts,
        .sizes = sizes,
    };
}
