//! What happens to a binary between its last chunk and its symbol table. Building the table
//! sorts every function of the file, which takes long for a big one, so it is not done on the
//! run's thread: that thread is the agent's loop, and while it waits the agent drains no
//! samples. The upload hands its buffers over as one `Received`, the server queues it, and a
//! thread of its own builds the tables, one at a time.

const std = @import("std");
const agent = @import("agent");
const elf = @import("shared").elf;
const SymbolTable = @import("symbol_table.zig").SymbolTable;

const assert = std.debug.assert;
const Section = agent.binary.Section;

/// Every section of one binary, arrived whole and checked against its header. Owns its buffers.
pub const Received = struct {
    id: []u8,
    segments: []elf.Segment,
    /// The sections one after the other.
    data: []u8,
    starts: std.EnumArray(Section, usize),
    sizes: std.EnumArray(Section, usize),
    /// What the server reserved for it from the upload budget; given back once it is freed.
    reserved: u64 = 0,

    pub fn deinit(received: *Received, gpa: std.mem.Allocator) void {
        gpa.free(received.id);
        gpa.free(received.segments);
        gpa.free(received.data);
        received.* = undefined;
    }

    /// The symbol table of the binary. The buffers are only read: they are still to be freed.
    pub fn build(received: *const Received, gpa: std.mem.Allocator) !SymbolTable {
        return SymbolTable.init(gpa, .{
            .segments = received.segments,
            .symtab = received.section(.symtab),
            .strtab = received.section(.strtab),
            .dynsym = received.section(.dynsym),
            .dynstr = received.section(.dynstr),
        });
    }

    fn section(received: *const Received, which: Section) []const u8 {
        const start = received.starts.get(which);
        return received.data[start..][0..received.sizes.get(which)];
    }
};

/// The binaries waiting for their table, oldest first. Fixed in size: each run has one upload
/// in flight, so a few slots per run is plenty, and a full queue refuses instead of growing.
pub const Queue = struct {
    items: [items_max]Received = undefined,
    head: usize = 0,
    count: usize = 0,

    pub const items_max = 32;

    /// Takes `received`, or gives it back as an error when the queue is full.
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

    /// Frees what is still waiting.
    pub fn deinit(queue: *Queue, gpa: std.mem.Allocator) void {
        while (queue.pop()) |received| {
            var dropped = received;
            dropped.deinit(gpa);
        }
        queue.* = undefined;
    }
};

// ------------------------------------------------------------------------------------- tests

const testing = std.testing;

fn received_test(gpa: std.mem.Allocator, id: []const u8) !Received {
    return .{
        .id = try gpa.dupe(u8, id),
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

    // Fill it past the end of the array, so it wraps around.
    for (1..Queue.items_max) |_| try queue.push(try received_test(testing.allocator, "x"));
    var refused = try received_test(testing.allocator, "y");
    defer refused.deinit(testing.allocator);
    try testing.expectError(error.QueueFull, queue.push(refused));
    try testing.expectEqual(@as(usize, Queue.items_max), queue.count);
}
