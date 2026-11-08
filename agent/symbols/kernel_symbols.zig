//! The kernel's code symbols from /proc/kallsyms, sent like a binary's. Each is kept at its
//! distance from `_text`, which KASLR moves. Modules load elsewhere on every boot, so the
//! identity is the build ID and `_text`: good for one boot. Only root reads real addresses.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("shared").File;
const elf = @import("shared").elf;

/// The path a kernel frame is shown under, and the binary's name in the logs.
pub const path = "[kernel]";

/// The size of one Elf64_Sym.
const sym_bytes = 24;
/// More symbols than a kernel with every module loaded has (a few hundred thousand).
const symbols_max = 1 << 20;
/// The names of so many symbols: kept well under the server's budget for one binary.
const names_bytes_max = 64 * 1024 * 1024;
/// A kallsyms line: an address, a type, a name of at most KSYM_NAME_LEN (512), a module.
const line_bytes_max = 1024;

/// The identity of the kernel's symbols for this boot, in `buffer`: the build ID, then `_text`.
/// Null when the kernel does not say either.
pub fn id(buffer: *[id_bytes_max]u8, build_id: ?[]const u8, text_address: ?u64) ?[]const u8 {
    const kernel_id = build_id orelse return null;
    const text = text_address orelse return null;
    if (kernel_id.len == 0 or kernel_id.len + 8 > id_bytes_max) return null;
    @memcpy(buffer[0..kernel_id.len], kernel_id);
    std.mem.writeInt(u64, buffer[kernel_id.len..][0..8], text, .little);
    return buffer[0 .. kernel_id.len + 8];
}

/// Room for `id`: a build ID of at most 56 bytes and the 8 of `_text`.
pub const id_bytes_max = 64;

/// The one segment of the kernel's "file": every offset is its own address.
pub const segment = elf.Segment{ .offset = 0, .vaddr = 0, .filesz = std.math.maxInt(u64) };

pub const Symbols = struct {
    symtab: []const u8,
    strtab: []const u8,
    count: usize,
};

/// Reads kallsyms a piece per `step`: the kernel writes it as it is read, 0.6 s of CPU for all
/// of it, too long to hold up the agent's loop.
pub const Reader = struct {
    file: File,
    builder: Builder,
    /// The bytes read and not parsed yet: the start of a line cut by the end of the last read.
    buffer: []u8,
    kept: usize,
    done: bool,

    const buffer_bytes = 64 * 1024;

    /// Null when kallsyms cannot be opened. The buffer and the symbols are in `arena`.
    pub fn init(arena: std.mem.Allocator, text_address: u64) !?Reader {
        var file = File.open("/proc/kallsyms") catch return null;
        errdefer file.deinit();
        var reader = Reader{
            .file = file,
            .builder = .{ .arena = arena, .text_address = text_address },
            .buffer = try arena.alloc(u8, buffer_bytes),
            .kept = 0,
            .done = false,
        };
        try reader.builder.start();
        return reader;
    }

    pub fn deinit(reader: *Reader) void {
        reader.file.deinit();
        reader.* = undefined;
    }

    /// Reads and parses about `bytes_max` more of kallsyms. True once it is all read.
    pub fn step(reader: *Reader, bytes_max: usize) !bool {
        assert(!reader.done);
        assert(bytes_max > 0);
        var read_total: usize = 0;
        while (read_total < bytes_max) {
            const room = reader.buffer[reader.kept..];
            const got = try reader.file.read(room[0..@min(room.len, bytes_max - read_total)]);
            if (got == 0) {
                if (reader.kept > 0) try reader.builder.lines_add(reader.buffer[0..reader.kept]);
                reader.kept = 0;
                reader.done = true;
                return true;
            }
            read_total += got;
            const filled = reader.kept + got;
            const last = std.mem.lastIndexOfScalar(u8, reader.buffer[0..filled], '\n') orelse {
                if (filled == reader.buffer.len) return error.LineTooLong;
                reader.kept = filled;
                continue;
            };
            try reader.builder.lines_add(reader.buffer[0..last]);
            reader.kept = filled - last - 1;
            const rest = reader.buffer[last + 1 .. filled];
            std.mem.copyForwards(u8, reader.buffer[0..reader.kept], rest);
        }
        return false;
    }

    /// The symbols, once `step` said it is done. Null when the addresses were hidden (not root).
    pub fn symbols(reader: *const Reader) ?Symbols {
        assert(reader.done);
        return reader.builder.finish();
    }
};

/// The code symbols of /proc/kallsyms, as distances from `text_address`, in `arena`, read in
/// one go: for tests and tools, not the agent's loop. Null when the addresses are hidden.
pub fn read(arena: std.mem.Allocator, text_address: u64) !?Symbols {
    var reader = (try Reader.init(arena, text_address)) orelse return null;
    defer reader.deinit();
    while (!try reader.step(Reader.buffer_bytes)) {}
    return reader.symbols();
}

/// The same from text already read: for tests, and whatever has kallsyms at hand.
pub fn parse(arena: std.mem.Allocator, text: []const u8, text_address: u64) !?Symbols {
    var builder = Builder{ .arena = arena, .text_address = text_address };
    try builder.start();
    try builder.lines_add(text);
    return builder.finish();
}

const Builder = struct {
    arena: std.mem.Allocator,
    text_address: u64,
    symtab: std.ArrayList(u8) = .empty,
    strtab: std.ArrayList(u8) = .empty,
    count: usize = 0,
    /// Lines with an address of 0: the kernel hides them from this process.
    hidden: usize = 0,

    fn start(builder: *Builder) !void {
        // Symbol 0 and name 0 are empty, as in every ELF file.
        try builder.symtab.appendNTimes(builder.arena, 0, sym_bytes);
        try builder.strtab.append(builder.arena, 0);
    }

    fn lines_add(builder: *Builder, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| try builder.line_add(line);
    }

    /// One line: "ffffffff81000000 T _text", or "ffffffffc0a01000 t nft_do_chain\t[nf_tables]".
    fn line_add(builder: *Builder, line: []const u8) !void {
        if (line.len == 0 or line.len > line_bytes_max) return;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const address_text = fields.next() orelse return;
        const kind = fields.next() orelse return;
        const name = fields.next() orelse return;
        const module = fields.next(); // "[nf_tables]", for a module's symbol.

        // Code only: data symbols never hold a frame.
        if (kind.len != 1 or (kind[0] != 't' and kind[0] != 'T')) return;
        const address = std.fmt.parseInt(u64, address_text, 16) catch return;
        if (address == 0) {
            builder.hidden += 1;
            return;
        }
        if (builder.count == symbols_max) return;
        const name_bytes = name.len + if (module) |text| text.len + 2 else 1;
        if (builder.strtab.items.len + name_bytes > names_bytes_max) return;

        const name_offset: u32 = @intCast(builder.strtab.items.len);
        try builder.strtab.appendSlice(builder.arena, name);
        if (module) |text| {
            try builder.strtab.append(builder.arena, ' ');
            try builder.strtab.appendSlice(builder.arena, text);
        }
        try builder.strtab.append(builder.arena, 0);

        var sym: [sym_bytes]u8 = @splat(0);
        std.mem.writeInt(u32, sym[0..4], name_offset, .little);
        sym[4] = 0x12; // A global function.
        std.mem.writeInt(u16, sym[6..8], 1, .little); // Defined.
        // Kallsyms has no sizes: a function lasts until the next one (the server's rule).
        std.mem.writeInt(u64, sym[8..16], address -% builder.text_address, .little);
        try builder.symtab.appendSlice(builder.arena, &sym);
        builder.count += 1;
    }

    fn finish(builder: *const Builder) ?Symbols {
        if (builder.count == 0) return null;
        assert(builder.symtab.items.len == (builder.count + 1) * sym_bytes);
        return .{
            .symtab = builder.symtab.items,
            .strtab = builder.strtab.items,
            .count = builder.count,
        };
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn name_at(symbols: *const Symbols, index: usize) []const u8 {
    const sym = symbols.symtab[(index + 1) * sym_bytes ..][0..sym_bytes];
    const at = std.mem.readInt(u32, sym[0..4], .little);
    return std.mem.sliceTo(symbols.strtab[at..], 0);
}

fn value_at(symbols: *const Symbols, index: usize) u64 {
    const sym = symbols.symtab[(index + 1) * sym_bytes ..][0..sym_bytes];
    return std.mem.readInt(u64, sym[8..16], .little);
}

test "kallsyms lines become code symbols at their distance from _text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // As kallsyms writes it: a tab before a module's name.
    const text = "0000000000000000 A fixed_percpu_data\n" ++
        "ffffffff81000000 T _text\n" ++
        "ffffffff81000100 t do_one_initcall\n" ++
        "ffffffff82000000 D some_data\n" ++
        "ffffffffc0a01000 t nft_do_chain\t[nf_tables]\n" ++
        "not a line";
    const symbols = (try parse(arena.allocator(), text, 0xffffffff81000000)).?;

    try testing.expectEqual(@as(usize, 3), symbols.count); // Code only.
    try testing.expectEqualStrings("_text", name_at(&symbols, 0));
    try testing.expectEqual(@as(u64, 0), value_at(&symbols, 0));
    try testing.expectEqual(@as(u64, 0x100), value_at(&symbols, 1));
    // A module's symbol says which module.
    try testing.expectEqualStrings("nft_do_chain [nf_tables]", name_at(&symbols, 2));
    try testing.expectEqual(@as(u64, 0x3fa01000), value_at(&symbols, 2));
}

test "hidden addresses (not root) give nothing to send" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\0000000000000000 T _text
        \\0000000000000000 t do_one_initcall
    ;
    try testing.expectEqual(@as(?Symbols, null), try parse(arena.allocator(), text, 0));
}

test "the identity is the build ID and _text, and needs both" {
    var buffer: [id_bytes_max]u8 = undefined;
    const both = id(&buffer, "\xab\xcd", 0x1122).?;
    try testing.expectEqualSlices(u8, "\xab\xcd\x22\x11\x00\x00\x00\x00\x00\x00", both);
    try testing.expectEqual(@as(?[]const u8, null), id(&buffer, null, 0x1122));
    try testing.expectEqual(@as(?[]const u8, null), id(&buffer, "\xab", null));
}

test "kallsyms read a little at a time: hidden without root, the same symbols either way" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = (try Reader.init(arena.allocator(), 0xffffffff81000000)) orelse
        return error.SkipZigTest;
    defer reader.deinit();
    var steps: usize = 1;
    while (!try reader.step(4096)) steps += 1;
    try testing.expect(steps > 100); // Kallsyms is megabytes: it took many small steps.

    const stepped = reader.symbols() orelse {
        // Not root: every address reads as 0, and there is nothing to send.
        try testing.expect(std.os.linux.geteuid() != 0);
        return;
    };
    const whole = (try read(arena.allocator(), 0xffffffff81000000)).?;
    try testing.expectEqual(whole.count, stepped.count);
    try testing.expectEqualSlices(u8, whole.strtab, stepped.strtab);
}

test "this machine's kallsyms, when it shows addresses (root)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const symbols = (try read(arena.allocator(), 0xffffffff81000000)) orelse
        return error.SkipZigTest;
    std.debug.print("kernel: {d} code symbols, {d} KiB of names\n", .{
        symbols.count,
        symbols.strtab.len / 1024,
    });
    try testing.expect(symbols.count > 1000);
}
