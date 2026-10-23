//! Names for kernel addresses, from the text of /proc/kallsyms. The addresses in it are the
//! real runtime addresses, the same ones the agent reports, so no conversion is needed.
const std = @import("std");
const elf = @import("elf.zig");
const index = @import("index.zig");
const files = @import("files.zig");

pub const Match = index.Match;

/// A kallsyms text is around 10 MB. This only stops something absurd.
const max_kallsyms_bytes = 256 * 1024 * 1024;

pub const Kernel = struct {
    /// Owned. The names point into it.
    bytes: []u8,
    index: index.Index,
    /// The runtime address of `_text`. It changes at every boot, so it identifies the kernel.
    text_address: u64,

    /// Takes over `bytes` (a kallsyms text allocated with `allocator`), and frees it if this fails.
    pub fn parse(allocator: std.mem.Allocator, bytes: []u8) !Kernel {
        errdefer allocator.free(bytes);

        var symbols: std.ArrayList(elf.Symbol) = .empty;
        defer symbols.deinit(allocator);
        var text_address: ?u64 = null;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const parsed = parseLine(line) orelse continue;
            if (std.mem.eql(u8, parsed.name, "_text")) text_address = parsed.value;
            try symbols.append(allocator, .{ .name = parsed.name, .value = parsed.value, .size = 0 });
        }
        // Without permission to see addresses, every one reads as zero and nothing is left.
        if (symbols.items.len == 0) return error.NoSymbols;
        const text = text_address orelse return error.NoTextSymbol;

        const idx = try index.Index.fromSymbols(allocator, symbols.items);
        return .{ .bytes = bytes, .index = idx, .text_address = text };
    }

    /// Reads the running kernel's symbols. Needs root (or CAP_SYSLOG) to get real addresses.
    pub fn open(allocator: std.mem.Allocator) !Kernel {
        const bytes = try files.readAll(allocator, "/proc/kallsyms", max_kallsyms_bytes);
        return parse(allocator, bytes);
    }

    pub fn deinit(self: *Kernel, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// The function that contains the kernel address `addr`, or null.
    pub fn lookup(self: Kernel, addr: u64) ?Match {
        return self.index.lookup(addr);
    }
};

const Line = struct { value: u64, name: []const u8 };

/// A line looks like "ffffffff81000040 T secondary_startup_64", and for module code the
/// name is followed by a tab and "[module]". Only text symbols with a real address count.
fn parseLine(line: []const u8) ?Line {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const value = std.fmt.parseInt(u64, line[0..first_space], 16) catch return null;
    if (value == 0) return null;

    const rest = line[first_space + 1 ..];
    if (rest.len < 3 or rest[1] != ' ') return null;
    switch (rest[0]) {
        'T', 't', 'W', 'w' => {}, // text, and weak text
        else => return null,
    }
    const after_type = rest[2..];
    const end = std.mem.indexOfScalar(u8, after_type, '\t') orelse after_type.len;
    const name = after_type[0..end];
    if (name.len == 0) return null;
    return .{ .value = value, .name = name };
}

// ------------------------------------------------------------------ tests

pub const sample_kallsyms =
    "ffffffff81000000 T _text\n" ++
    "ffffffff81000000 T startup_64\n" ++
    "ffffffff81000040 T secondary_startup_64\n" ++
    "ffffffff81000100 t local_func\n" ++
    "ffffffff81000200 W weak_func\n" ++
    "ffffffff81000300 D some_data\n" ++
    "ffffffff81000300 d other_data\n" ++
    "ffffffff81000400 T do_something\t[mymod]\n" ++
    "0000000000000000 T hidden_function\n" ++
    "ffffffff81000500 T _etext\n";

fn testKernel(text: []const u8) !Kernel {
    return Kernel.parse(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
}

test "parse keeps the text symbols and skips data, hidden addresses and the module tag" {
    var k = try testKernel(sample_kallsyms);
    defer k.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0xffffffff81000000), k.text_address);
    // _text and startup_64 share an address; the others are 4 more, and _etext is the last.
    try std.testing.expectEqual(@as(usize, 6), k.index.entries.len);

    const start = k.lookup(0xffffffff81000000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("startup_64", start.name); // fewer underscores than _text
    try std.testing.expectEqual(@as(u64, 0), start.offset);

    const second = k.lookup(0xffffffff81000050) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("secondary_startup_64", second.name);
    try std.testing.expectEqual(@as(u64, 0x10), second.offset);

    // No sizes: a function reaches up to the next text symbol.
    try std.testing.expectEqualStrings("secondary_startup_64", k.lookup(0xffffffff810000ff).?.name);
    try std.testing.expectEqualStrings("local_func", k.lookup(0xffffffff81000100).?.name);
    try std.testing.expectEqualStrings("weak_func", k.lookup(0xffffffff81000200).?.name);
    // Data symbols are not functions, so what lies after them still belongs to the function before.
    try std.testing.expectEqualStrings("weak_func", k.lookup(0xffffffff81000350).?.name);
    // The module tag is cut off the name.
    try std.testing.expectEqualStrings("do_something", k.lookup(0xffffffff81000400).?.name);
}

test "lookup: the last symbol only matches exactly, and nothing below the first one is found" {
    var k = try testKernel(sample_kallsyms);
    defer k.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("_etext", k.lookup(0xffffffff81000500).?.name);
    try std.testing.expect(k.lookup(0xffffffff81000501) == null);
    try std.testing.expect(k.lookup(0xffffffff80ffffff) == null);
    try std.testing.expect(k.lookup(0) == null);
}

test "parse ignores lines that are not symbols" {
    var k = try testKernel(
        "garbage\n" ++
            "\n" ++
            "zzzz T not_hex\n" ++
            "ffffffff81000000 T _text\n" ++
            "ffffffff81000010 X not_a_text_type\n" ++
            "ffffffff81000020 T\n" ++
            "ffffffff81000030 T real_function\n",
    );
    defer k.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), k.index.entries.len);
    try std.testing.expectEqualStrings("real_function", k.lookup(0xffffffff81000030).?.name);
}

test "parse: hidden addresses give NoSymbols, and a kernel without _text gives NoTextSymbol" {
    try std.testing.expectError(
        error.NoSymbols,
        testKernel("0000000000000000 T a\n0000000000000000 T b\n"),
    );
    try std.testing.expectError(
        error.NoTextSymbol,
        testKernel("ffffffff81000100 T foo\n"),
    );
    try std.testing.expectError(error.NoSymbols, testKernel(""));
    // The testing allocator reports a leak if parse had not freed the bytes on those errors.
}
