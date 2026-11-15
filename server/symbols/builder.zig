//! A binary between its last chunk and its symbol table.

const std = @import("std");
const protocol = @import("shared").protocol;
const elf = @import("shared").elf;
const SymbolTable = @import("symbol_table.zig").SymbolTable;
const dwarf_load = @import("dwarf/loader.zig");
const dwarf_builder = @import("dwarf/builder.zig");

const Debug_Info = @import("debug_files.zig").Info;

const assert = std.debug.assert;
const Section = protocol.binary.Section;

pub const Received = struct {
    id: []u8,
    path: []u8,
    segments: []elf.Segment,
    data: []u8,
    starts: std.EnumArray(Section, usize),
    sizes: std.EnumArray(Section, usize),
    compressed: std.EnumSet(Section) = .initEmpty(),
    /// Some sections came from the binary's debug file, which the agent found and sent.
    debug_file: bool = false,
    reserved: u64 = 0,

    pub fn deinit(received: *Received, gpa: std.mem.Allocator) void {
        gpa.free(received.id);
        gpa.free(received.path);
        gpa.free(received.segments);
        gpa.free(received.data);
        received.* = undefined;
    }

    pub fn stripped(received: *const Received) bool {
        return received.sizes.get(.symtab) == 0 or received.sizes.get(.debug_info) == 0;
    }

    pub fn build(received: *const Received, gpa: std.mem.Allocator, debug: ?*const Debug_Info) !SymbolTable {
        const own_symtab = received.sizes.get(.symtab) > 0;
        const from_debug = !own_symtab and debug != null and debug.?.symtab.len > 0;
        var own_dwarf = try received.dwarf_own(gpa);
        defer if (own_dwarf) |*loaded| loaded.deinit(gpa);

        const sections: ?dwarf_builder.Sections = if (own_dwarf) |loaded|
            loaded.sections
        else if (debug) |found|
            if (found.dwarf) |loaded| loaded.sections else null
        else
            null;

        return SymbolTable.init(gpa, .{
            .segments = received.segments,
            .symtab = if (from_debug) debug.?.symtab else received.section(.symtab),
            .strtab = if (from_debug) debug.?.strtab else received.section(.strtab),
            .dynsym = received.section(.dynsym),
            .dynstr = received.section(.dynstr),
            .dwarf = sections,
        });
    }

    fn dwarf_own(received: *const Received, gpa: std.mem.Allocator) !?dwarf_load.Loaded {
        if (received.sizes.get(.debug_info) == 0) return null;
        var loaded = dwarf_load.Loaded{};
        errdefer loaded.deinit(gpa);
        const first = @intFromEnum(Section.debug_info);
        inline for (comptime std.enums.values(Section)) |which| {
            if (comptime @intFromEnum(which) >= first) {
                const compressed = received.compressed.contains(which);
                const index = @intFromEnum(which) - first;
                const raw = received.section(which);
                loaded.put(gpa, index, raw, compressed) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.Malformed => {
                        loaded.deinit(gpa);
                        return null;
                    },
                };
            }
        }
        return loaded;
    }

    fn section(received: *const Received, which: Section) []const u8 {
        const start = received.starts.get(which);
        return received.data[start..][0..received.sizes.get(which)];
    }
};

pub const Queue = struct {
    items: [items_max]Received = undefined,
    head: usize = 0,
    count: usize = 0,

    pub const items_max = 32;

    pub fn push(queue: *Queue, received: Received) error{QueueFull}!void {
        assert(queue.count <= items_max);
        if (queue.count == items_max) return error.QueueFull;
        queue.items[(queue.head + queue.count) % items_max] = received;
        queue.count += 1;
    }

    pub fn pop(queue: *Queue) ?Received {
        if (queue.count == 0) return null;
        const received = queue.items[queue.head];
        queue.head = (queue.head + 1) % items_max;
        queue.count -= 1;
        return received;
    }

    pub fn has(queue: *const Queue, build_id: []const u8) bool {
        for (0..queue.count) |age| {
            const received = &queue.items[(queue.head + age) % items_max];
            if (std.mem.eql(u8, received.id, build_id)) return true;
        }
        return false;
    }

    pub fn deinit(queue: *Queue, gpa: std.mem.Allocator) void {
        while (queue.pop()) |received| {
            var dropped = received;
            dropped.deinit(gpa);
        }
        queue.* = undefined;
    }
};

const testing = std.testing;

fn received_test(gpa: std.mem.Allocator, id: []const u8) !Received {
    return .{
        .id = try gpa.dupe(u8, id),
        .path = try gpa.dupe(u8, "/test"),
        .segments = try gpa.alloc(elf.Segment, 0),
        .data = try gpa.alloc(u8, 0),
        .starts = .initFill(0),
        .sizes = .initFill(0),
    };
}

test "the queue keeps its order, knows what waits in it, and refuses past its size" {
    var queue = Queue{};
    defer queue.deinit(testing.allocator);

    try queue.push(try received_test(testing.allocator, "a"));
    try queue.push(try received_test(testing.allocator, "b"));
    try testing.expect(queue.has("a") and queue.has("b") and !queue.has("c"));

    var first = queue.pop().?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("a", first.id);
    try testing.expect(!queue.has("a"));

    for (1..Queue.items_max) |_| try queue.push(try received_test(testing.allocator, "x"));
    var refused = try received_test(testing.allocator, "y");
    defer refused.deinit(testing.allocator);
    try testing.expectError(error.QueueFull, queue.push(refused));
    try testing.expectEqual(@as(usize, Queue.items_max), queue.count);
}
