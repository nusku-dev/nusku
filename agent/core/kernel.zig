//! Which kernel is running. The backend needs this to resolve kernel frames: the build ID
//! finds the matching vmlinux (the symbols), and the text address undoes KASLR, the random
//! shift of the kernel's position in memory at each boot.
const std = @import("std");
const sys = @import("sys.zig");
const buildid = @import("buildid.zig");

pub const Identity = struct {
    /// For example "6.8.0-45-generic". Empty if it could not be read.
    release: []const u8 = "",
    /// The GNU build ID of the kernel image. Null if the kernel has none or it is unreadable.
    build_id: ?[]const u8 = null,
    /// The run-time address of the kernel's `_text` symbol. Null when the kernel hides it
    /// (needs CAP_SYSLOG or root) or it could not be read.
    text_address: ?u64 = null,
};

/// The run-time address of `_text` in the first part of /proc/kallsyms, falling back to
/// `_stext`, which sits at the same address on current kernels. Addresses printed as zero
/// are hidden by kptr_restrict and count as missing.
/// The first non-zero address printed for `symbol`. Zero means the kernel hides addresses.
fn addressOf(kallsyms: []const u8, symbol: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, kallsyms, '\n');
    while (lines.next()) |line| {
        // A line is: "address type name", and module symbols add "\t[module]".
        var fields = std.mem.splitScalar(u8, line, ' ');
        const address_text = fields.next() orelse continue;
        _ = fields.next() orelse continue; // the symbol type
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, name, symbol)) continue;
        const address = std.fmt.parseInt(u64, address_text, 16) catch continue;
        if (address != 0) return address;
    }
    return null;
}

/// The run-time address of `_text` in `kallsyms`, falling back to `_stext`, which sits at the
/// same address on current kernels. Addresses printed as zero are hidden by kptr_restrict.
pub fn textAddressFrom(kallsyms: []const u8) ?u64 {
    return addressOf(kallsyms, "_text") orelse addressOf(kallsyms, "_stext");
}

/// Reads kallsyms front to back in chunks and stops at `_text`. The first lines are per-CPU
/// variables with tiny addresses, so `_text` can be tens of kilobytes in; reading only the
/// start of the file would miss it. `source` is anything with `readAt(buf, offset)`.
fn scan(comptime chunk: usize, source: anytype) ?u64 {
    var buf: [chunk]u8 = undefined;
    var kept: usize = 0; // bytes of an unfinished line, kept at the start of buf
    var offset: u64 = 0;
    var stext: ?u64 = null;
    const limit = 4 * 1024 * 1024; // no kernel has _text this deep

    while (offset < limit) {
        const n = source.readAt(buf[kept..], offset) catch break;
        if (n == 0) break;
        offset += n;
        const filled = kept + n;

        // Work on whole lines only. No newline at all means a line longer than the buffer,
        // which is not kallsyms.
        const lines_end = (std.mem.lastIndexOfScalar(u8, buf[0..filled], '\n') orelse break) + 1;
        if (addressOf(buf[0..lines_end], "_text")) |address| return address;
        if (stext == null) stext = addressOf(buf[0..lines_end], "_stext");

        kept = filled - lines_end;
        std.mem.copyForwards(u8, buf[0..kept], buf[lines_end..filled]);
    }
    return stext;
}

fn trimEnd(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r' or text[end - 1] == ' ')) end -= 1;
    return text[0..end];
}

/// Reads a small file, or returns null if it cannot be read. Only out of memory is an error.
fn readOrNull(allocator: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) std.mem.Allocator.Error!?[]u8 {
    return sys.readFile(allocator, path, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Reads the identity of the running kernel. Whatever the kernel does not tell us is left
/// empty or null: a missing piece must never fail a profile. Everything returned lives in `arena`.
pub fn read(arena: std.mem.Allocator) std.mem.Allocator.Error!Identity {
    var identity = Identity{};

    if (try readOrNull(arena, "/proc/sys/kernel/osrelease", 256)) |text| {
        identity.release = trimEnd(text);
    }

    // /sys/kernel/notes holds the kernel image's ELF notes: the same format as in any binary.
    if (try readOrNull(arena, "/sys/kernel/notes", 64 * 1024)) |notes| {
        identity.build_id = buildid.findBuildId(notes); // points into `notes`, which `arena` owns
    }

    if (sys.File.openRead("/proc/kallsyms")) |opened| {
        var file = opened;
        defer file.deinit();
        identity.text_address = scan(16 * 1024, file);
    } else |_| {}

    return identity;
}

// ------------------------------------------------------------------ tests

test "text address: _text wins, _stext is the fallback, hidden addresses give null" {
    const normal = "ffffffff81000000 T _stext\nffffffff81000000 T _text\nffffffff81000000 T startup_64\n";
    try std.testing.expectEqual(@as(?u64, 0xffffffff81000000), textAddressFrom(normal));

    const stext_only = "ffffffff82000000 T _stext\nffffffff82000100 T other\n";
    try std.testing.expectEqual(@as(?u64, 0xffffffff82000000), textAddressFrom(stext_only));

    const hidden = "0000000000000000 T _text\n0000000000000000 T _stext\n";
    try std.testing.expectEqual(@as(?u64, null), textAddressFrom(hidden));

    try std.testing.expectEqual(@as(?u64, null), textAddressFrom(""));
    try std.testing.expectEqual(@as(?u64, null), textAddressFrom("ffffffff81000000 T _te")); // cut off
    try std.testing.expectEqual(@as(?u64, null), textAddressFrom("ffffffff81000000 T something_else\n"));
}

test "this machine: reads the kernel identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const id = try read(arena.allocator());
    std.debug.print("kernel {s}\n", .{id.release});
    if (id.build_id) |b| std.debug.print("  build id {x}\n", .{b}) else std.debug.print("  build id: none\n", .{});
    if (id.text_address) |t| std.debug.print("  _text at 0x{x}\n", .{t}) else std.debug.print("  _text: hidden or unreadable\n", .{});

    try std.testing.expect(id.release.len > 0 and id.release[0] >= '0' and id.release[0] <= '9');
    if (id.build_id) |b| try std.testing.expect(b.len >= 16 and b.len <= 64);
}

const MemorySource = struct {
    bytes: []const u8,

    fn readAt(self: MemorySource, buf: []u8, offset: u64) anyerror!usize {
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const n = @min(buf.len, self.bytes.len - start);
        @memcpy(buf[0..n], self.bytes[start..][0..n]);
        return n;
    }
};

test "scan finds _text far into the file, whichever way the chunks fall" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);

    // Like the start of a real kallsyms: per-CPU variables with tiny addresses come first.
    for (0..200) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "{x:0>16} A percpu_symbol_{d}\n", .{ i * 8, i });
        defer std.testing.allocator.free(line);
        try text.appendSlice(std.testing.allocator, line);
    }
    try text.appendSlice(std.testing.allocator, "ffffffff9fe00000 T _stext\nffffffff9fe00000 T _text\nffffffff9fe00010 T startup_64\n");

    inline for (.{ 40, 64, 100, 1000 }) |chunk| {
        try std.testing.expectEqual(@as(?u64, 0xffffffff9fe00000), scan(chunk, MemorySource{ .bytes = text.items }));
    }
}

test "scan: only _stext gives _stext, hidden addresses and junk give null" {
    const stext_only = "0000000000000000 A fixed_percpu_data\nffffffff82000000 T _stext\nffffffff82000100 T other\n";
    try std.testing.expectEqual(@as(?u64, 0xffffffff82000000), scan(64, MemorySource{ .bytes = stext_only }));

    const hidden = "0000000000000000 T _text\n0000000000000000 T _stext\n";
    try std.testing.expectEqual(@as(?u64, null), scan(64, MemorySource{ .bytes = hidden }));

    try std.testing.expectEqual(@as(?u64, null), scan(64, MemorySource{ .bytes = "" }));
    try std.testing.expectEqual(@as(?u64, null), scan(64, MemorySource{ .bytes = "x" ** 500 })); // no newline
}
