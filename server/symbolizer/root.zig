//! Turns raw stack addresses into names. It knows nothing about the agent: the controller
//! converts the agent's report into the `Window` below.
const std = @import("std");
const store = @import("store.zig");
pub const binary = @import("binary.zig");
const kallsyms = @import("kernel.zig");

const Binary = binary.Binary;
const Kernel = kallsyms.Kernel;
// ------------------------------------------------------------------ input

pub const Region = struct {
    start: u64,
    end: u64,
    /// The offset inside the file that `start` corresponds to.
    offset: u64,
    /// Empty for anonymous memory, "[vdso]" for the vDSO.
    path: []const u8,
    /// The inode the agent saw. 0 means unknown. Only used for files without a build ID.
    inode: u64 = 0,
    build_id: ?[]const u8,
};

pub const KernelIdentity = struct {
    release: []const u8 = "",
    build_id: ?[]const u8 = null,
    text_address: ?u64 = null,
};

pub const Stack = struct {
    samples: u64,
    /// Return addresses, innermost first, exactly as the agent reports them.
    user: []const u64,
    kernel: []const u64,
    /// Whether the innermost user address is a return address (the sample was inside a system
    /// call) or the exact instruction that was running. Null means the agent did not say, and
    /// then a sample with kernel frames is taken to be inside a system call.
    leaf_is_return: ?bool = null,
    stop: u8 = 0,
};

pub const Window = struct {
    pid: u32,
    regions: []const Region,
    kernel: KernelIdentity = .{},
    stacks: []const Stack,
};

// ----------------------------------------------------------------- output

pub const FrameKind = enum { user, kernel };

pub const Frame = struct {
    kind: FrameKind,
    /// The runtime address where the function the name belongs to starts. Two frames with
    /// the same `function` are the same function, whatever address inside it they have.
    /// Null while the frame is unresolved.
    function: ?u64 = null,
    address: u64,
    /// Null means not resolved (yet).
    name: ?[]const u8 = null,
    /// The file the address lies in. Null if it lies in no known region, or in anonymous memory.
    module: ?[]const u8 = null,
};

pub const SymbolizedStack = struct {
    samples: u64,
    /// Root first: the outermost user frame comes first and the innermost kernel frame last.
    frames: []const Frame,
    stop: u8 = 0,
};

pub const Result = struct {
    /// The sum of `samples` over `stacks`.
    samples: u64,
    stacks: []const SymbolizedStack,
};

pub const KernelSource = enum {
    /// Read /proc/kallsyms of the machine the server runs on.
    proc,
    /// Never look: kernel names only come from `addKernel`. For tests.
    none,
};

const KernelSlot = struct {
    text_address: u64,
    /// Null if the symbols for that kernel could not be had; remembered so nobody retries per window.
    kernel: ?Kernel,
};

/// Finds names for the addresses of a window. It keeps every binary it loads, so a binary
/// is read and indexed once, however many windows or processes use it.
pub const Symbolizer = struct {
    allocator: std.mem.Allocator,
    /// Keyed by build ID (the keys are owned). A null value means the binary could not be
    /// loaded; that is remembered so a missing file is not looked up again in every window.
    cache: std.StringHashMapUnmanaged(?Binary) = .empty,
    kernel: ?KernelSlot = null,
    kernel_source: KernelSource = .proc,

    pub fn init(allocator: std.mem.Allocator) Symbolizer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Symbolizer) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |*loaded| loaded.deinit(self.allocator);
        }
        if (self.kernel) |*slot| {
            if (slot.kernel) |*k| k.deinit(self.allocator);
        }
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds a binary under a build ID without going through the file system. For tests.
    pub fn addBinary(self: *Symbolizer, build_id: []const u8, loaded: Binary) !void {
        var key_buf: [cache_key_max]u8 = undefined;
        const key = cacheKey(&key_buf, 0, "", .{ .build_id = build_id }) orelse return error.KeyTooLong;
        try self.put(key, loaded);
    }

    /// The same for a file known only by its inode. For tests.
    pub fn addInodeBinary(self: *Symbolizer, pid: u32, path: []const u8, inode: u64, loaded: Binary) !void {
        var key_buf: [cache_key_max]u8 = undefined;
        const key = cacheKey(&key_buf, pid, path, .{ .inode = inode }) orelse return error.KeyTooLong;
        try self.put(key, loaded);
    }

    fn put(self: *Symbolizer, key: []const u8, loaded: ?Binary) !void {
        std.debug.assert(!self.cache.contains(key));
        const owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned);
        try self.cache.put(self.allocator, owned, loaded);
    }

    fn discard(self: *Symbolizer, loaded: ?Binary) void {
        if (loaded) |b| {
            var owned = b;
            owned.deinit(self.allocator);
        }
    }

    /// Names every user address it can. The names live in `arena`; `module` still points into
    /// the window's regions, so the window must outlive the result.
    pub fn symbolize(self: *Symbolizer, arena: std.mem.Allocator, window: Window) !Result {
        const out = try arena.alloc(SymbolizedStack, window.stacks.len);
        var total: u64 = 0;

        for (window.stacks, out) |stack, *dst| {
            const frames = try arena.alloc(Frame, stack.user.len + stack.kernel.len);
            var n: usize = 0;

            // The agent gives innermost first; we want root first. A sample runs user code
            // first and then, for a syscall, kernel code, so user frames come before kernel ones.
            var i = stack.user.len;
            while (i > 0) {
                i -= 1;
                // Only the innermost frame of a sample taken in user code is an exact
                // instruction address; every other frame is a return address.
                const leaf_return = stack.leaf_is_return orelse (stack.kernel.len != 0);
                const is_return = i != 0 or leaf_return;
                frames[n] = try self.userFrame(arena, window, stack.user[i], is_return);
                n += 1;
            }

            i = stack.kernel.len;
            while (i > 0) {
                i -= 1;
                // The innermost kernel frame is the exact instruction that was running;
                // every other one is a return address.
                frames[n] = try self.kernelFrame(arena, window.kernel, stack.kernel[i], i != 0);
                n += 1;
            }

            dst.* = .{ .samples = stack.samples, .frames = frames, .stop = stack.stop };
            total += stack.samples;
        }
        return .{ .samples = total, .stacks = out };
    }

    fn userFrame(self: *Symbolizer, arena: std.mem.Allocator, window: Window, address: u64, is_return: bool) !Frame {
        var frame = Frame{ .kind = .user, .address = address };
        const region = regionOf(window.regions, address) orelse return frame;
        if (region.path.len > 0) frame.module = region.path;

        // A return address points just after the call, which can already be the next function.
        const probe = if (is_return and address > region.start) address - 1 else address;
        const bin = self.binaryFor(window.pid, region.*) orelse return frame;
        const file_offset = std.math.add(u64, probe - region.start, region.offset) catch return frame;
        if (bin.resolve(file_offset)) |match| {
            frame.name = try arena.dupe(u8, match.name);
            frame.function = probe - match.offset;
        }
        return frame;
    }

    /// Gives the symbolizer kernel symbols for the kernel whose `_text` is at `text_address`.
    /// For tests.
    pub fn addKernel(self: *Symbolizer, text_address: u64, loaded: Kernel) void {
        std.debug.assert(self.kernel == null);
        self.kernel = .{ .text_address = text_address, .kernel = loaded };
    }

    fn kernelFrame(self: *Symbolizer, arena: std.mem.Allocator, identity: KernelIdentity, address: u64, is_return: bool) !Frame {
        var frame = Frame{ .kind = .kernel, .address = address };
        const known = self.kernelFor(identity) orelse return frame;

        const probe = if (is_return and address > 0) address - 1 else address;
        if (known.lookup(probe)) |match| {
            frame.name = try arena.dupe(u8, match.name);
            frame.function = probe - match.offset;
        }
        return frame;
    }

    /// The symbols of the kernel the agent saw, or null. They are used only if the kernel is
    /// known to be the same one: its `_text` address (new at every boot) must be equal.
    fn kernelFor(self: *Symbolizer, identity: KernelIdentity) ?*const Kernel {
        // Without the agent's text address there is nothing to compare, so no names.
        const text_address = identity.text_address orelse return null;

        if (self.kernel) |*slot| {
            if (slot.text_address == text_address) return if (slot.kernel) |*k| k else null;
            // A different kernel (the machine rebooted): forget the old symbols.
            if (slot.kernel) |*old| old.deinit(self.allocator);
            self.kernel = null;
        }

        var loaded: ?Kernel = null;
        if (self.kernel_source == .proc) {
            if (Kernel.open(self.allocator)) |opened| {
                if (opened.text_address == text_address) {
                    loaded = opened;
                } else {
                    var wrong = opened;
                    wrong.deinit(self.allocator);
                }
            } else |_| {}
        }
        self.kernel = .{ .text_address = text_address, .kernel = loaded };
        return if (self.kernel.?.kernel) |*k| k else null;
    }

    /// The loaded binary behind a region, or null if its file cannot be identified or loaded.
    /// The pointer is only good until the next call, because the cache may grow.
    fn binaryFor(self: *Symbolizer, pid: u32, region: Region) ?*const Binary {
        const identity = identityOf(region) orelse return null;
        var key_buf: [cache_key_max]u8 = undefined;
        const key = cacheKey(&key_buf, pid, region.path, identity) orelse return null;

        if (self.cache.getPtr(key)) |slot| {
            return if (slot.*) |*loaded| loaded else null;
        }

        const loaded: ?Binary = store.openLocal(self.allocator, pid, region.path, identity) catch null;
        self.put(key, loaded) catch {
            self.discard(loaded);
            return null;
        };
        const slot = self.cache.getPtr(key).?;
        return if (slot.*) |*b| b else null;
    }

    /// Loads the kernel symbols now instead of when the first report arrives, so that work
    /// does not delay the first window. Does nothing if they cannot be read (the first report
    /// then tries again), or if they are already there.
    pub fn preloadKernel(self: *Symbolizer) void {
        if (self.kernel_source != .proc or self.kernel != null) return;
        const loaded = Kernel.open(self.allocator) catch return;
        self.kernel = .{ .text_address = loaded.text_address, .kernel = loaded };
    }
};
const cache_key_max = 4200;

/// A build ID is a fingerprint of the content and is preferred. Without one, the inode the
/// agent saw is used; 0 means the agent did not know it.
fn identityOf(region: Region) ?store.Identity {
    if (region.build_id) |id| return .{ .build_id = id };
    if (region.inode != 0) return .{ .inode = region.inode };
    return null;
}

/// The cache key of a file, written into `buf`; null if it does not fit. A build ID means the
/// same file on every machine, so it is the whole key. An inode only means something inside
/// one process's file system, so the pid and the path are part of the key, and the first byte
/// keeps the two kinds from ever being equal.
fn cacheKey(buf: []u8, pid: u32, path: []const u8, identity: store.Identity) ?[]const u8 {
    switch (identity) {
        .build_id => |id| {
            if (1 + id.len > buf.len) return null;
            buf[0] = 'b';
            @memcpy(buf[1..][0..id.len], id);
            return buf[0 .. 1 + id.len];
        },
        .inode => |inode| {
            const head = 1 + 4 + 8;
            if (head + path.len > buf.len) return null;
            buf[0] = 'i';
            std.mem.writeInt(u32, buf[1..5], pid, .little);
            std.mem.writeInt(u64, buf[5..13], inode, .little);
            @memcpy(buf[head..][0..path.len], path);
            return buf[0 .. head + path.len];
        },
    }
}

fn regionOf(regions: []const Region, address: u64) ?*const Region {
    for (regions) |*r| {
        if (address >= r.start and address < r.end) return r;
    }
    return null;
}

/// Merges stacks that are the same once resolved, adding up their samples. The frames of
/// the first stack of each group are kept. The result is hottest first.
pub fn merge(arena: std.mem.Allocator, result: Result) !Result {
    const stacks = result.stacks;

    // Sort so equal stacks sit next to each other. Ties go by original position, so the
    // first stack of a group is the one whose frames are kept.
    const order = try arena.alloc(usize, stacks.len);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, stacks, framesThenPosition);

    var entries: std.ArrayList(Entry) = .empty;
    for (order) |i| {
        const stack = stacks[i];
        if (entries.items.len > 0) {
            const last = &entries.items[entries.items.len - 1];
            if (compareStacks(last.stack, stack) == .eq) {
                last.stack.samples += stack.samples;
                continue;
            }
        }
        try entries.append(arena, .{ .stack = stack, .first = i });
    }

    // Hottest first; equal counts keep the order they came in.
    std.mem.sort(Entry, entries.items, {}, hotterFirst);

    const out = try arena.alloc(SymbolizedStack, entries.items.len);
    for (entries.items, out) |entry, *dst| dst.* = entry.stack;
    return .{ .samples = result.samples, .stacks = out };
}

const Entry = struct { stack: SymbolizedStack, first: usize };

fn framesThenPosition(stacks: []const SymbolizedStack, a: usize, b: usize) bool {
    const order = compareStacks(stacks[a], stacks[b]);
    if (order != .eq) return order == .lt;
    return a < b;
}

fn hotterFirst(_: void, a: Entry, b: Entry) bool {
    if (a.stack.samples != b.stack.samples) return a.stack.samples > b.stack.samples;
    return a.first < b.first;
}

fn compareStacks(a: SymbolizedStack, b: SymbolizedStack) std.math.Order {
    const common = @min(a.frames.len, b.frames.len);
    for (a.frames[0..common], b.frames[0..common]) |x, y| {
        const order = compareFrames(x, y);
        if (order != .eq) return order;
    }
    return std.math.order(a.frames.len, b.frames.len);
}

/// Two frames are the same if they are the same function. A frame without a function is
/// only the same as another one with the same address.
fn compareFrames(a: Frame, b: Frame) std.math.Order {
    if (a.kind != b.kind) return std.math.order(@intFromEnum(a.kind), @intFromEnum(b.kind));
    const a_resolved = a.function != null;
    const b_resolved = b.function != null;
    if (a_resolved != b_resolved) return std.math.order(@intFromBool(a_resolved), @intFromBool(b_resolved));
    return std.math.order(a.function orelse a.address, b.function orelse b.address);
}

// ------------------------------------------------------------------ tests

const test_regions = [_]Region{
    .{ .start = 0x1000, .end = 0x2000, .offset = 0, .path = "/bin/app", .build_id = null },
    .{ .start = 0x5000, .end = 0x6000, .offset = 0, .path = "", .build_id = null }, // anonymous
};

fn testFrame(kind: FrameKind, address: u64, function: ?u64) Frame {
    return .{ .kind = kind, .address = address, .function = function, .name = if (function != null) "f" else null };
}

test "merge: stacks that differ only in the address inside the same functions become one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = [_]Frame{ testFrame(.user, 0x1010, 0x1000), testFrame(.user, 0x2020, 0x2000) };
    const b = [_]Frame{ testFrame(.user, 0x1018, 0x1000), testFrame(.user, 0x2020, 0x2000) };
    const c = [_]Frame{ testFrame(.user, 0x1010, 0x1000), testFrame(.user, 0x3030, 0x3000) };
    const stacks = [_]SymbolizedStack{
        .{ .samples = 20, .frames = &a },
        .{ .samples = 3, .frames = &b },
        .{ .samples = 5, .frames = &c },
    };
    const merged = try merge(arena.allocator(), .{ .samples = 28, .stacks = &stacks });

    try std.testing.expectEqual(@as(u64, 28), merged.samples);
    try std.testing.expectEqual(@as(usize, 2), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 23), merged.stacks[0].samples);
    try std.testing.expectEqual(@as(u64, 0x1010), merged.stacks[0].frames[0].address); // the first stack's frames are kept
    try std.testing.expectEqual(@as(u64, 5), merged.stacks[1].samples);
}

test "merge: the result is hottest first, and equal counts keep their original order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const x = [_]Frame{testFrame(.user, 0x1, 0x1)};
    const y = [_]Frame{testFrame(.user, 0x2, 0x2)};
    const z = [_]Frame{testFrame(.user, 0x3, 0x3)};
    const w = [_]Frame{testFrame(.user, 0x4, 0x4)};
    const stacks = [_]SymbolizedStack{
        .{ .samples = 1, .frames = &x },
        .{ .samples = 5, .frames = &y },
        .{ .samples = 5, .frames = &z },
        .{ .samples = 9, .frames = &w },
    };
    const merged = try merge(arena.allocator(), .{ .samples = 20, .stacks = &stacks });

    try std.testing.expectEqual(@as(usize, 4), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 0x4), merged.stacks[0].frames[0].address);
    try std.testing.expectEqual(@as(u64, 0x2), merged.stacks[1].frames[0].address);
    try std.testing.expectEqual(@as(u64, 0x3), merged.stacks[2].frames[0].address);
    try std.testing.expectEqual(@as(u64, 0x1), merged.stacks[3].frames[0].address);
}

test "merge keeps stacks apart when a frame differs in kind, in being resolved, or in address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const user_unresolved = [_]Frame{testFrame(.user, 0x1000, null)};
    const kernel_unresolved = [_]Frame{testFrame(.kernel, 0x1000, null)};
    const user_resolved = [_]Frame{testFrame(.user, 0x1000, 0x1000)};
    const other_address = [_]Frame{testFrame(.user, 0x1004, null)};
    const longer = [_]Frame{ testFrame(.user, 0x1000, null), testFrame(.user, 0x2000, null) };
    const stacks = [_]SymbolizedStack{
        .{ .samples = 1, .frames = &user_unresolved },
        .{ .samples = 1, .frames = &kernel_unresolved },
        .{ .samples = 1, .frames = &user_resolved },
        .{ .samples = 1, .frames = &other_address },
        .{ .samples = 1, .frames = &longer },
    };
    const merged = try merge(arena.allocator(), .{ .samples = 5, .stacks = &stacks });
    try std.testing.expectEqual(@as(usize, 5), merged.stacks.len);
}

test "merge: unresolved frames merge when their addresses are equal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = [_]Frame{testFrame(.user, 0x1000, null)};
    const b = [_]Frame{testFrame(.user, 0x1000, null)};
    const stacks = [_]SymbolizedStack{ .{ .samples = 2, .frames = &a }, .{ .samples = 3, .frames = &b } };
    const merged = try merge(arena.allocator(), .{ .samples = 5, .stacks = &stacks });

    try std.testing.expectEqual(@as(usize, 1), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 5), merged.stacks[0].samples);
}

test "merge: nothing to merge gives nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const merged = try merge(arena.allocator(), .{ .samples = 0, .stacks = &.{} });
    try std.testing.expectEqual(@as(usize, 0), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 0), merged.samples);
}

test "symbolized stacks that land in the same function at different addresses merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try fakeSymbolizer();
    defer sym.deinit();

    // 0x7040 and 0x7060 are both inside main (0x7030 to 0x706f); 0x7080 is inside helper.
    const stacks = [_]Stack{
        .{ .samples = 1, .user = &.{0x7040}, .kernel = &.{} },
        .{ .samples = 2, .user = &.{0x7060}, .kernel = &.{} },
        .{ .samples = 4, .user = &.{0x7080}, .kernel = &.{} },
    };
    const raw = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &fake_regions, .stacks = &stacks });
    try std.testing.expectEqual(@as(usize, 3), raw.stacks.len);
    try std.testing.expectEqual(@as(?u64, 0x7030), raw.stacks[0].frames[0].function);

    const merged = try merge(arena.allocator(), raw);
    try std.testing.expectEqual(@as(usize, 2), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 7), merged.samples);
    try std.testing.expectEqualStrings("helper", merged.stacks[0].frames[0].name.?); // 4 samples
    try std.testing.expectEqual(@as(u64, 4), merged.stacks[0].samples);
    try std.testing.expectEqualStrings("main", merged.stacks[1].frames[0].name.?); // 1 + 2 samples
    try std.testing.expectEqual(@as(u64, 3), merged.stacks[1].samples);
}

test "frames are root first: user outermost to innermost, then kernel outermost to innermost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = Symbolizer.init(std.testing.allocator);
    defer sym.deinit();

    const stacks = [_]Stack{
        .{ .samples = 3, .user = &.{ 0x1010, 0x1020, 0x1030 }, .kernel = &.{ 0xffff0001, 0xffff0002 } },
        .{ .samples = 2, .user = &.{}, .kernel = &.{} },
    };
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &test_regions, .stacks = &stacks });

    try std.testing.expectEqual(@as(u64, 5), result.samples);
    try std.testing.expectEqual(@as(usize, 2), result.stacks.len);

    const first = result.stacks[0];
    try std.testing.expectEqual(@as(u64, 3), first.samples);
    try std.testing.expectEqual(@as(usize, 5), first.frames.len);
    try std.testing.expectEqual(@as(u64, 0x1030), first.frames[0].address); // outermost user
    try std.testing.expectEqual(@as(u64, 0x1010), first.frames[2].address); // innermost user
    try std.testing.expectEqual(@as(u64, 0xffff0002), first.frames[3].address); // outermost kernel
    try std.testing.expectEqual(@as(u64, 0xffff0001), first.frames[4].address); // innermost kernel
    try std.testing.expectEqual(FrameKind.user, first.frames[2].kind);
    try std.testing.expectEqual(FrameKind.kernel, first.frames[3].kind);

    try std.testing.expectEqual(@as(usize, 0), result.stacks[1].frames.len);
}

test "the module is the file of the region, null outside regions and in anonymous memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = Symbolizer.init(std.testing.allocator);
    defer sym.deinit();

    // Innermost first: 0x1500 is inside /bin/app, 0x9000 is in no region, 0x2000 is the
    // exclusive end of /bin/app, 0x5500 is anonymous memory.
    const stacks = [_]Stack{
        .{ .samples = 1, .user = &.{ 0x1500, 0x9000, 0x2000, 0x5500 }, .kernel = &.{} },
    };
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &test_regions, .stacks = &stacks });
    const frames = result.stacks[0].frames; // root first, so the reverse of the input

    try std.testing.expectEqual(@as(u64, 0x5500), frames[0].address);
    try std.testing.expect(frames[0].module == null);
    try std.testing.expect(frames[1].module == null);
    try std.testing.expect(frames[2].module == null);
    try std.testing.expectEqualStrings("/bin/app", frames[3].module.?);
}

test "nothing is resolved yet: every name is null and kernel frames have no module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var sym = Symbolizer.init(std.testing.allocator);
    defer sym.deinit();

    const stacks = [_]Stack{
        .{ .samples = 1, .user = &.{0x1500}, .kernel = &.{0xffff0001} },
    };
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &test_regions, .stacks = &stacks });
    for (result.stacks[0].frames) |frame| {
        try std.testing.expect(frame.name == null);
    }
    try std.testing.expect(result.stacks[0].frames[1].module == null);
}

const fake_id = "fake-build-id";

/// One region that shows the hand-made binary from binary.zig: process address 0x7000 is
/// file offset 0x100, which that binary loads at virtual address 0x1100. So address 0x7030
/// is the start of `main` (0x1130, size 0x40) and 0x7070 is the start of `helper` (0x1170, size 0x20).
const fake_regions = [_]Region{
    .{ .start = 0x7000, .end = 0x7200, .offset = 0x100, .path = "/bin/fake", .build_id = fake_id },
};

fn fakeSymbolizer() !Symbolizer {
    var sym = Symbolizer.init(std.testing.allocator);
    errdefer sym.deinit();
    var buf: [binary.glue_size]u8 = undefined;
    binary.glueFile(&buf);
    const bytes = try std.testing.allocator.dupe(u8, &buf);
    try sym.addBinary(fake_id, try Binary.load(std.testing.allocator, bytes));
    return sym;
}

test "user frames get the name of the function they lie in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try fakeSymbolizer();
    defer sym.deinit();

    // Innermost first: 0x7080 is inside helper (exact instruction), 0x7050 is a return
    // address inside main.
    const stacks = [_]Stack{.{ .samples = 1, .user = &.{ 0x7080, 0x7050 }, .kernel = &.{} }};
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &fake_regions, .stacks = &stacks });
    const frames = result.stacks[0].frames; // root first

    try std.testing.expectEqualStrings("main", frames[0].name.?);
    try std.testing.expectEqualStrings("helper", frames[1].name.?);
    try std.testing.expectEqualStrings("/bin/fake", frames[0].module.?);
    try std.testing.expectEqualStrings("/bin/fake", frames[1].module.?);
}

test "a return address is looked up one byte earlier, so a call at the end of a function stays in it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try fakeSymbolizer();
    defer sym.deinit();

    // 0x7070 is the first byte of helper. As the exact instruction it is helper; as a
    // return address it means "the call that ended main just before it".
    const user_only = [_]Stack{.{ .samples = 1, .user = &.{ 0x7070, 0x7070 }, .kernel = &.{} }};
    const first = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &fake_regions, .stacks = &user_only });
    try std.testing.expectEqualStrings("main", first.stacks[0].frames[0].name.?); // user[1], a return address
    try std.testing.expectEqualStrings("helper", first.stacks[0].frames[1].name.?); // user[0], exact

    // With a kernel stack the sample was taken in the kernel, so user[0] is a return address too.
    const with_kernel = [_]Stack{.{ .samples = 1, .user = &.{0x7070}, .kernel = &.{0xffff0001} }};
    const second = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &fake_regions, .stacks = &with_kernel });
    try std.testing.expectEqualStrings("main", second.stacks[0].frames[0].name.?);
    try std.testing.expect(second.stacks[0].frames[1].name == null); // kernel frames are not resolved yet
}

test "what cannot be resolved stays an address with its module, and failing is remembered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try fakeSymbolizer();
    defer sym.deinit();

    const regions = [_]Region{
        .{ .start = 0x9000, .end = 0xa000, .offset = 0, .path = "/does/not/exist", .build_id = "unknown-id" },
        .{ .start = 0xb000, .end = 0xc000, .offset = 0, .path = "/bin/nobuildid", .build_id = null },
    };
    const stacks = [_]Stack{
        .{ .samples = 1, .user = &.{ 0x9100, 0xb100, 0x7ff00, 0x7090 }, .kernel = &.{} },
    };
    // Twice, so the second pass is served from the cache of failures.
    for (0..2) |_| {
        const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &regions, .stacks = &stacks });
        const frames = result.stacks[0].frames; // root first: the reverse of the input
        try std.testing.expect(frames[0].name == null and frames[0].module == null); // 0x7090: no region here
        try std.testing.expect(frames[1].name == null and frames[1].module == null); // 0x7ff00
        try std.testing.expectEqualStrings("/bin/nobuildid", frames[2].module.?); // no build ID, no name
        try std.testing.expect(frames[2].name == null);
        try std.testing.expectEqualStrings("/does/not/exist", frames[3].module.?); // file cannot be opened
        try std.testing.expect(frames[3].name == null);
    }
}

const kernel_text: u64 = 0xffffffff81000000;

fn kernelSymbolizer() !Symbolizer {
    var sym = Symbolizer.init(std.testing.allocator);
    errdefer sym.deinit();
    sym.kernel_source = .none;
    const bytes = try std.testing.allocator.dupe(u8, kallsyms.sample_kallsyms);
    sym.addKernel(kernel_text, try Kernel.parse(std.testing.allocator, bytes));
    return sym;
}

test "kernel frames get names: the innermost is exact, the others are return addresses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try kernelSymbolizer();
    defer sym.deinit();

    // Innermost first. 0x...110 is inside local_func. 0x...100 is the first byte of
    // local_func, so as a return address it means the call that ended the function before it.
    const stacks = [_]Stack{.{ .samples = 1, .user = &.{}, .kernel = &.{ 0xffffffff81000110, 0xffffffff81000100 } }};
    const result = try sym.symbolize(arena.allocator(), .{
        .pid = 1,
        .regions = &.{},
        .kernel = .{ .text_address = kernel_text },
        .stacks = &stacks,
    });
    const frames = result.stacks[0].frames; // root first

    try std.testing.expectEqualStrings("secondary_startup_64", frames[0].name.?);
    try std.testing.expectEqual(@as(?u64, 0xffffffff81000040), frames[0].function);
    try std.testing.expectEqualStrings("local_func", frames[1].name.?);
    try std.testing.expectEqual(@as(?u64, 0xffffffff81000100), frames[1].function);
    try std.testing.expectEqual(FrameKind.kernel, frames[0].kind);
    try std.testing.expect(frames[1].module == null);
}

test "kernel names are only used when the kernel is known to be the same one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try kernelSymbolizer();
    defer sym.deinit();

    const stacks = [_]Stack{.{ .samples = 1, .user = &.{}, .kernel = &.{0xffffffff81000110} }};

    // The agent did not report the text address: nothing to compare, so no names.
    const unknown = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &.{}, .kernel = .{}, .stacks = &stacks });
    try std.testing.expect(unknown.stacks[0].frames[0].name == null);

    // Another kernel (another boot has another text address): the symbols are not used.
    const other = try sym.symbolize(arena.allocator(), .{
        .pid = 1,
        .regions = &.{},
        .kernel = .{ .text_address = 0x1234 },
        .stacks = &stacks,
    });
    try std.testing.expect(other.stacks[0].frames[0].name == null);

    // And the old symbols were dropped, so the original address finds nothing either now
    // (this symbolizer is not allowed to look at the real machine).
    const again = try sym.symbolize(arena.allocator(), .{
        .pid = 1,
        .regions = &.{},
        .kernel = .{ .text_address = kernel_text },
        .stacks = &stacks,
    });
    try std.testing.expect(again.stacks[0].frames[0].name == null);
}

test "user and kernel frames of one sample are both resolved, and stacks merge on kernel functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try kernelSymbolizer();
    defer sym.deinit();

    // Two samples in local_func at different addresses.
    const stacks = [_]Stack{
        .{ .samples = 2, .user = &.{}, .kernel = &.{0xffffffff81000110} },
        .{ .samples = 3, .user = &.{}, .kernel = &.{0xffffffff81000140} },
    };
    const raw = try sym.symbolize(arena.allocator(), .{
        .pid = 1,
        .regions = &.{},
        .kernel = .{ .text_address = kernel_text },
        .stacks = &stacks,
    });
    const merged = try merge(arena.allocator(), raw);
    try std.testing.expectEqual(@as(usize, 1), merged.stacks.len);
    try std.testing.expectEqual(@as(u64, 5), merged.stacks[0].samples);
}

test "preloadKernel does nothing when the symbolizer may not read the machine" {
    var sym = Symbolizer.init(std.testing.allocator);
    defer sym.deinit();
    sym.kernel_source = .none;

    sym.preloadKernel();
    try std.testing.expect(sym.kernel == null);
}

test "preloadKernel keeps the symbols it already has" {
    var sym = try kernelSymbolizer();
    defer sym.deinit();
    sym.kernel_source = .proc; // it would read the machine if it did not already have symbols

    sym.preloadKernel();
    try std.testing.expectEqual(kernel_text, sym.kernel.?.text_address);
}

test "preloadKernel on the real machine fills the cache when run as root" {
    var sym = Symbolizer.init(std.testing.allocator);
    defer sym.deinit();

    sym.preloadKernel();
    std.debug.print("preloadKernel: {s}\n", .{if (sym.kernel != null) "loaded" else "not loaded (not root?)"});
    if (sym.kernel) |slot| {
        try std.testing.expect(slot.kernel != null);
        try std.testing.expectEqual(slot.text_address, slot.kernel.?.text_address);
    }
}

fn inodeSymbolizer(pid: u32) !Symbolizer {
    var sym = Symbolizer.init(std.testing.allocator);
    errdefer sym.deinit();
    sym.kernel_source = .none;
    var buf: [binary.glue_size]u8 = undefined;
    binary.glueFile(&buf);
    const bytes = try std.testing.allocator.dupe(u8, &buf);
    try sym.addInodeBinary(pid, "/bin/noid", 77, try Binary.load(std.testing.allocator, bytes));
    return sym;
}

fn noidRegion(inode: u64) Region {
    return .{ .start = 0x7000, .end = 0x7200, .offset = 0x100, .path = "/bin/noid", .build_id = null, .inode = inode };
}

test "a file without a build ID is trusted by its inode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try inodeSymbolizer(1);
    defer sym.deinit();

    const regions = [_]Region{noidRegion(77)};
    const stacks = [_]Stack{.{ .samples = 1, .user = &.{0x7040}, .kernel = &.{} }};
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &regions, .stacks = &stacks });
    try std.testing.expectEqualStrings("main", result.stacks[0].frames[0].name.?);
    try std.testing.expectEqualStrings("/bin/noid", result.stacks[0].frames[0].module.?);
}

test "another inode, another process, or no inode at all is not that file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try inodeSymbolizer(1);
    defer sym.deinit();

    const stacks = [_]Stack{.{ .samples = 1, .user = &.{0x7040}, .kernel = &.{} }};

    // The file with that path has another inode now: it is not the file we loaded.
    const other_inode = [_]Region{noidRegion(78)};
    const a = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &other_inode, .stacks = &stacks });
    try std.testing.expect(a.stacks[0].frames[0].name == null);

    // The same path and inode in another process may be another file system: no sharing.
    const same = [_]Region{noidRegion(77)};
    const b = try sym.symbolize(arena.allocator(), .{ .pid = 2, .regions = &same, .stacks = &stacks });
    try std.testing.expect(b.stacks[0].frames[0].name == null);

    // The agent did not know the inode (0) and there is no build ID: nothing to go by.
    const unknown = [_]Region{noidRegion(0)};
    const c = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &unknown, .stacks = &stacks });
    try std.testing.expect(c.stacks[0].frames[0].name == null);
    try std.testing.expectEqualStrings("/bin/noid", c.stacks[0].frames[0].module.?);
}

test "a build ID wins over the inode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sym = try fakeSymbolizer();
    defer sym.deinit();

    // Registered under a build ID. The inode of this region is nonsense and must not matter.
    const regions = [_]Region{.{
        .start = 0x7000,
        .end = 0x7200,
        .offset = 0x100,
        .path = "/bin/fake",
        .build_id = fake_id,
        .inode = 999,
    }};
    const stacks = [_]Stack{.{ .samples = 1, .user = &.{0x7040}, .kernel = &.{} }};
    const result = try sym.symbolize(arena.allocator(), .{ .pid = 1, .regions = &regions, .stacks = &stacks });
    try std.testing.expectEqualStrings("main", result.stacks[0].frames[0].name.?);
}
