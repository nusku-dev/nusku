const std = @import("std");
const File = @import("../clibs/file.zig").File;

const assert = std.debug.assert;

const build_id = @import("build_id.zig");

pub const Identity = struct {
    /// For example "6.8.0-45-generic". Empty if it could not be read.
    release: []const u8 = "",
    /// The GNU build ID of the kernel image. Null if the kernel has none or it is unreadable.
    build_id: ?[]const u8 = null,
    /// The run-time address of the kernel's `_text` symbol. Null when the kernel hides it
    /// (needs CAP_SYSLOG or root) or it could not be read.
    text_address: ?u64 = null,
};

/// Reads the identity of the running kernel. Whatever the kernel does not tell us is left
/// empty or null: a missing piece must never fail a profile. Everything returned lives in `arena`.
pub fn read(arena: std.mem.Allocator) !Identity {
    var identity = Identity{};

    if (try readOrNull(arena, "/proc/sys/kernel/osrelease", 256)) |text| {
        identity.release = trim_end(text);
    }

    // /sys/kernel/notes holds the kernel image's ELF notes: the same format as in any binary.
    if (try readOrNull(arena, "/sys/kernel/notes", 64 * 1024)) |notes| {
        identity.build_id = build_id.find_build_id(notes); // points into `notes`, which `arena` owns
    }

    if (File.open("/proc/kallsyms")) |opened| {
        var file = opened;
        defer file.deinit();
        identity.text_address = scan(16 * 1024, file);
    } else |_| {}

    return identity;
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
        const n = source.read_at(buf[kept..], offset) catch break;
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

/// Reads a small file, or returns null if it cannot be read. Only out of memory is an error.
fn readOrNull(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) !?[]u8 {
    return read_file(gpa, path, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn read_file(gpa: std.mem.Allocator, path: [:0]const u8, max_bytes: usize) ![]u8 {
    var file = try File.open(path);
    defer file.deinit();
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&chunk);
        if (n == 0) break;
        const len: usize = @intCast(n);
        if (list.items.len + len > max_bytes) return error.TooLarge;
        try list.appendSlice(gpa, chunk[0..len]);
    }
    return list.toOwnedSlice(gpa);
}

fn trim_end(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r' or text[end - 1] == ' ')) end -= 1;
    return text[0..end];
}
