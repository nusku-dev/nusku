//! Reads Go's pclntab: the table the Go runtime itself uses for tracebacks. Go binaries carry no
//! .eh_frame, and `-ldflags="-s -w"` (common in production images) removes .debug_frame too, but
//! .gopclntab is always there, because the runtime needs it.
//!
//! For unwinding only one of its tables matters: pcsp, which gives, for every instruction of a
//! function, how far the stack pointer is below its value at the function's entry. On x86-64 the
//! caller's frame then follows exactly: CFA = rsp + sp_delta + 8, the return address at CFA - 8.
//!
//! Layout, for Go 1.18 and later (magic 0xfffffff0, and 0xfffffff1 since Go 1.20), from
//! runtime/symtab.go and internal/abi/symtab.go:
//!
//!     pcHeader   magic u32, pad u8 u8, minLC u8, ptrSize u8, nfunc, nfiles, textStart,
//!                funcnameOffset, cuOffset, filetabOffset, pctabOffset, pclnOffset (all u64)
//!     functab    at pclnOffset: nfunc+1 pairs {entryOff u32, funcOff u32}, the last one the end
//!     _func      at pclnOffset + funcOff: entryOff, nameOff, args, deferreturn, pcsp, ... flag
//!
//! Older Go versions use other layouts and are refused (Unsupported): their binaries then have
//! no table, and frame pointers unwind them as before.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ Truncated, Unsupported, Malformed };

const magic_go1_18: u32 = 0xfffffff0;
const magic_go1_20: u32 = 0xfffffff1;
const header_size = 72;

/// The function is the outermost frame of a stack (runtime.goexit, mstart, rt0_go).
pub const flag_top_frame: u8 = 1 << 0;
/// The function writes the stack pointer by other means than its frame (systemstack, mcall,
/// morestack): pcsp cannot describe its frame, and Go's own traceback stops there too.
pub const flag_sp_write: u8 = 1 << 1;

pub const Function = struct {
    /// The first instruction, as an address in the file.
    entry: u64,
    /// The next function's entry: the end of this one, padding included.
    next_entry: u64,
    flag: u8,
    /// The function's pcsp table: the encoded (value delta, pc delta) pairs. Empty when the
    /// function has none.
    pcsp: []const u8,
};

pub const Pclntab = struct {
    bytes: []const u8,
    /// Every function's entryOff is relative to this address.
    text_start: u64,
    function_count: u32,
    functab_offset: u64,
    pctab_offset: u64,
    /// Where `flag` is inside a _func: Go 1.20 added a field before it.
    flag_offset: u32,

    /// `text_vaddr` is the address of the .text section, used when the header leaves textStart
    /// for a relocation to fill in (the linker writes 0 in the file).
    pub fn init(bytes: []const u8, text_vaddr: u64) Error!Pclntab {
        if (bytes.len < header_size) return error.Truncated;
        const magic = int_read(u32, bytes, 0) catch unreachable; // Checked just above.
        const flag_offset: u32 = switch (magic) {
            magic_go1_18 => 37, // funcID u8 at 36, then flag.
            magic_go1_20 => 41, // startLine i32 at 36, funcID at 40, then flag.
            else => return error.Unsupported,
        };
        if (bytes[6] != 1) return error.Unsupported; // minLC: one-byte instruction quantum.
        if (bytes[7] != 8) return error.Unsupported; // ptrSize: 64-bit.

        const function_count = std.math.cast(u32, try int_read(u64, bytes, 8)) orelse
            return error.Malformed;
        const text_start_header = try int_read(u64, bytes, 24);
        const pclntab = Pclntab{
            .bytes = bytes,
            .text_start = if (text_start_header != 0) text_start_header else text_vaddr,
            .function_count = function_count,
            .pctab_offset = try int_read(u64, bytes, 56),
            .functab_offset = try int_read(u64, bytes, 64),
            .flag_offset = flag_offset,
        };
        // The whole functab, end entry included, is inside the table.
        const functab_size = (@as(u64, function_count) + 1) * 8;
        if (pclntab.functab_offset > bytes.len) return error.Truncated;
        if (functab_size > bytes.len - pclntab.functab_offset) return error.Truncated;
        if (pclntab.pctab_offset > bytes.len) return error.Truncated;
        return pclntab;
    }

    pub fn function(pclntab: *const Pclntab, index: u32) Error!Function {
        assert(index < pclntab.function_count);
        const entry_at = pclntab.functab_offset + @as(u64, index) * 8;
        const entry_offset = try int_read(u32, pclntab.bytes, entry_at);
        const next_entry_offset = try int_read(u32, pclntab.bytes, entry_at + 8);
        const func_offset = try int_read(u32, pclntab.bytes, entry_at + 4);
        if (next_entry_offset < entry_offset) return error.Malformed; // The table is sorted.

        const func_at = pclntab.functab_offset + func_offset;
        // The _func's own entryOff repeats the functab's: a cheap check that we read a _func.
        if (try int_read(u32, pclntab.bytes, func_at) != entry_offset) return error.Malformed;
        const pcsp_offset = try int_read(u32, pclntab.bytes, func_at + 16);
        const flag = try int_read(u8, pclntab.bytes, func_at + pclntab.flag_offset);

        const pcsp_at = pclntab.pctab_offset + pcsp_offset;
        if (pcsp_at > pclntab.bytes.len) return error.Truncated;
        return .{
            .entry = pclntab.text_start + entry_offset,
            .next_entry = pclntab.text_start + next_entry_offset,
            .flag = flag,
            // Offset 0 means the function has no table (pctab starts with a 0 kept for that).
            .pcsp = if (pcsp_offset == 0) &.{} else pclntab.bytes[@intCast(pcsp_at)..],
        };
    }
};

/// One range of a function's pcsp table: from `start` up to `end`, rsp is `sp_delta` bytes below
/// its value at the function's entry.
pub const Range = struct { start: u64, end: u64, sp_delta: i32 };

/// Decodes a pcsp table, as runtime.step does. The value starts at -1; each pair is a zigzag
/// varint value delta and a varint pc delta; a zero value delta after the first pair ends it.
pub const PcspIterator = struct {
    bytes: []const u8,
    position: usize = 0,
    pc: u64,
    value: i64 = -1,
    first: bool = true,

    /// Every pair reads at least two bytes of a bounded slice, so the iteration ends.
    pub fn next(iterator: *PcspIterator) Error!?Range {
        const value_delta_encoded = try varint_read(iterator.bytes, &iterator.position);
        if (value_delta_encoded == 0 and !iterator.first) return null;
        iterator.first = false;

        const value_delta: i64 = if (value_delta_encoded & 1 != 0)
            -@as(i64, @intCast(value_delta_encoded >> 1)) - 1
        else
            @intCast(value_delta_encoded >> 1);
        const pc_delta = try varint_read(iterator.bytes, &iterator.position);

        iterator.value = std.math.add(i64, iterator.value, value_delta) catch
            return error.Malformed;
        const start = iterator.pc;
        iterator.pc = std.math.add(u64, iterator.pc, pc_delta) catch return error.Malformed;
        const sp_delta = std.math.cast(i32, iterator.value) orelse return error.Malformed;
        return .{ .start = start, .end = iterator.pc, .sp_delta = sp_delta };
    }
};

/// An unsigned LEB128 number, at most 32 bits as Go writes them.
fn varint_read(bytes: []const u8, position: *usize) Error!u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (shift < 35) : (shift += 7) {
        if (position.* >= bytes.len) return error.Truncated;
        const byte = bytes[position.*];
        position.* += 1;
        if (shift == 28 and byte > 0x0f) return error.Malformed; // Past 32 bits.
        result |= @as(u32, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return result;
    }
    return error.Malformed;
}

fn int_read(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    const end = std.math.add(u64, offset, @sizeOf(T)) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

test "pcsp: the ranges of a function that pushes rbp, grows its frame, and returns" {
    // As main.middle of a Go 1.26 program: 0 for 16 bytes, 8 for 10, 152 for 136, then 8, 0.
    // Value deltas are zigzag: +1 -> 2, +8 -> 16, +144 -> 288, -144 -> 287, -8 -> 15.
    const table = [_]u8{
        0x02, 0x10, // +1 (to 0), 16 bytes
        0x10, 0x0a, // +8, 10 bytes
        0xa0, 0x02, 0x88, 0x01, // +144, 136 bytes
        0x9f, 0x02, 0x01, // -144, 1 byte
        0x0f, 0x01, // -8, 1 byte
        0x00, // the end
    };
    var iterator = PcspIterator{ .bytes = &table, .pc = 0x1000 };
    const expected = [_]Range{
        .{ .start = 0x1000, .end = 0x1010, .sp_delta = 0 },
        .{ .start = 0x1010, .end = 0x101a, .sp_delta = 8 },
        .{ .start = 0x101a, .end = 0x10a2, .sp_delta = 152 },
        .{ .start = 0x10a2, .end = 0x10a3, .sp_delta = 8 },
        .{ .start = 0x10a3, .end = 0x10a4, .sp_delta = 0 },
    };
    for (expected) |range| {
        const found = (try iterator.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(range, found);
    }
    try testing.expect((try iterator.next()) == null);
}

test "pcsp: a table cut short, or with a number past 32 bits, is an error" {
    var cut = PcspIterator{ .bytes = &.{ 0x02, 0x90 }, .pc = 0 };
    try testing.expectError(error.Truncated, cut.next());

    var long = PcspIterator{ .bytes = &.{ 0x02, 0xff, 0xff, 0xff, 0xff, 0x7f }, .pc = 0 };
    try testing.expectError(error.Malformed, long.next());
}

test "a header of another Go version, or another architecture, is refused" {
    var header: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 0xfffffffb, .little); // Go 1.2 to 1.15.
    header[6] = 1;
    header[7] = 8;
    try testing.expectError(error.Unsupported, Pclntab.init(&header, 0x401000));

    std.mem.writeInt(u32, header[0..4], magic_go1_20, .little);
    header[7] = 4; // 32-bit.
    try testing.expectError(error.Unsupported, Pclntab.init(&header, 0x401000));
    try testing.expectError(error.Truncated, Pclntab.init(header[0..10], 0x401000));
}
