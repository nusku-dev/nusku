//! Builds Go programs for the tests, and finds their functions. Test-only, like all of testing/.
//!
//! Needs a Go toolchain. Under sudo, PATH is reset, so the usual install places are tried too;
//! without one the tests that need it are skipped.

const std = @import("std");
const assert = std.debug.assert;
const File = @import("../os/file.zig").File;
const elf_sections = @import("../unwind/elf_sections.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

const go_candidates = [_][:0]const u8{ "/usr/local/go/bin/go", "/usr/bin/go", "/snap/bin/go" };

pub const Build = struct {
    /// The temporary directory holding the source, the Go caches and the binary.
    directory: [:0]u8,
    /// The binary, inside `directory`.
    binary: [:0]u8,

    pub fn deinit(built: *Build, gpa: std.mem.Allocator) void {
        // Test code: the directory goes with rm, there is no recursive delete to write here.
        const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", built.directory.ptr };
        run(&argv, &.{}) catch {};
        gpa.free(built.binary);
        gpa.free(built.directory);
        built.* = undefined;
    }
};

/// Writes `source` as the main package of a module in a new temporary directory and builds it.
/// `ldflags` goes to `go build -ldflags`. Null when there is no Go toolchain.
pub fn build(gpa: std.mem.Allocator, source: []const u8, ldflags: [:0]const u8) !?Build {
    const go = go_find() orelse return null;

    var template = "/tmp/nusku-go-XXXXXX".*;
    const directory_pointer = mkdtemp(&template) orelse return error.TemporaryDirectoryFailed;
    const directory = try gpa.dupeZ(u8, std.mem.span(directory_pointer));
    errdefer gpa.free(directory);

    try file_write(gpa, directory, "main.go", source);
    try file_write(gpa, directory, "go.mod", "module nuskutest\n\ngo 1.21\n");

    const binary = try std.fmt.allocPrintSentinel(gpa, "{s}/program", .{directory}, 0);
    errdefer gpa.free(binary);
    const home = try std.fmt.allocPrintSentinel(gpa, "HOME={s}", .{directory}, 0);
    defer gpa.free(home);
    const cache = try std.fmt.allocPrintSentinel(gpa, "GOCACHE={s}/cache", .{directory}, 0);
    defer gpa.free(cache);
    const flags = try std.fmt.allocPrintSentinel(gpa, "-ldflags={s}", .{ldflags}, 0);
    defer gpa.free(flags);
    // -C must come first: go runs in that directory, where go.mod is.
    const argv = [_:null]?[*:0]const u8{
        go.ptr, "-C", directory.ptr, "build", flags.ptr, "-o", binary.ptr, ".",
    };
    // A clean environment: no download of another toolchain, caches inside the directory.
    const environment = [_:null]?[*:0]const u8{
        home.ptr, cache.ptr, "GOTOOLCHAIN=local", "GOFLAGS=", "CGO_ENABLED=0", "PATH=/usr/bin:/bin",
    };
    try run(&argv, &environment);
    return .{ .directory = directory, .binary = binary };
}

fn go_find() ?[:0]const u8 {
    for (go_candidates) |candidate| {
        if (std.c.access(candidate.ptr, std.c.X_OK) == 0) return candidate;
    }
    return null;
}

fn file_write(
    gpa: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ directory, name }, 0);
    defer gpa.free(path);
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(path.ptr, flags, @as(c_uint, 0o644));
    if (fd < 0) return error.FileWriteFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) {
        return error.FileWriteFailed;
    }
}

/// Runs a program to completion, and fails unless it exits with 0.
pub fn run(argv: [*:null]const ?[*:0]const u8, environment: [*:null]const ?[*:0]const u8) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = std.c.execve(argv[0].?, argv, environment);
        std.c._exit(127);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    if (status != 0) return error.CommandFailed;
}

/// Starts the built program as a child. Kill it with testing/process.zig's child_reap.
pub fn spawn(binary: [:0]const u8) !u32 {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{binary.ptr};
        const environment = [_:null]?[*:0]const u8{};
        _ = std.c.execve(binary.ptr, &argv, &environment);
        std.c._exit(127);
    }
    return @intCast(pid);
}

pub const Range = struct { start: u64, end: u64 };

/// The address range of the function `name`, from the binary's symbol table.
pub fn symbol_range(file: []const u8, name: []const u8) !?Range {
    const symbols_section = (try elf_sections.find(file, ".symtab")) orelse return null;
    const names_section = (try elf_sections.find(file, ".strtab")) orelse return null;
    const symbols = elf_sections.bytes_of(file, symbols_section) orelse return null;
    const names = elf_sections.bytes_of(file, names_section) orelse return null;

    // An Elf64_Sym: name u32, info u8, other u8, section u16, value u64, size u64.
    var offset: usize = 0;
    while (offset + 24 <= symbols.len) : (offset += 24) {
        const name_offset = std.mem.readInt(u32, symbols[offset..][0..4], .little);
        if (name_offset >= names.len) continue;
        if (!std.mem.eql(u8, std.mem.sliceTo(names[name_offset..], 0), name)) continue;
        const value = std.mem.readInt(u64, symbols[offset + 8 ..][0..8], .little);
        const size = std.mem.readInt(u64, symbols[offset + 16 ..][0..8], .little);
        return .{ .start = value, .end = value + size };
    }
    return null;
}

/// The whole file, for reading its symbols.
pub fn file_read_whole(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    var file = try File.open(path);
    defer file.deinit();
    const size: usize = @intCast(try file.size_bytes());
    const bytes = try gpa.alloc(u8, size);
    errdefer gpa.free(bytes);
    if (try file.read_at(bytes, 0) != size) return error.ReadFailed;
    return bytes;
}
