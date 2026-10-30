const Maps = @import("maps.zig").Maps;
const std = @import("std");
const ELF = @import("../../elf/parser.zig").ELF;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const sys = @import("../../libc/sys.zig");
const l = @import("../../loader/loader.zig");
const m = @import("../../loader/map.zig");

const stack_record = @import("../../kernel/shared/stack_record.zig");

const Error = l.Error;
const Loader = l.Loader;

const Slot = stack_record.OnCpuStackState;
const CountKey = stack_record.StackCountKey;

pub const CountEntry = struct {
    key: CountKey,
    count: u64,
};

/// The counters of all CPUs added up.
pub const Totals = struct {
    walks: u64 = 0,
    kernel_walks: u64 = 0,
    sent: u64 = 0,
    dropped: u64 = 0,
    repeats: u64 = 0,
    map_full: u64 = 0,
    stops: [16]u64 = [_]u64{0} ** 16,
};

pub const OnCpu = struct {
    gpa: std.mem.Allocator,
    loader: Loader,
    maps: Maps,
    ring_buffer: RingBuffer,
    num_cpus: u32,
    program_fd: c_int,

    pub fn init(gpa: std.mem.Allocator) !OnCpu {
        const elf = try ELF.init(@embedFile("oncpu_bpf"));
        var loader = Loader.init(gpa, elf);
        errdefer loader.deinit();

        var maps = try Maps.init(gpa, loader);
        errdefer maps.deinit();

        const maps_list = maps.list();
        const program_fd = try loader.load(.perf_event, "perf_event/oncpu_walk", "sampleOnCpuStack", &maps_list);

        const key = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(@as(u32, @intCast(program_fd)));
        try maps.get(.oncpu_stack_continuations).map.update(&key, &value);
        const ring = maps.get(.sample_ring_buffer);
        const ring_buffer = try RingBuffer.init(gpa, ring.map.fd);

        return OnCpu{
            .gpa = gpa,
            .loader = loader,
            .maps = maps,
            .program_fd = program_fd,
            .ring_buffer = ring_buffer,
            .num_cpus = @intCast(try sys.numPossibleCpus()),
        };
    }

    /// Samples of `pid` are recorded from now on (0 stops recording).
    pub fn setTarget(self: *OnCpu, pid: u32) !void {
        const index = std.mem.toBytes(@as(u32, 0));
        const value = std.mem.toBytes(pid);
        try self.maps.get(.target_pid).map.update(&index, &value);
    }

    /// The counters of the program, added up over all CPUs.
    pub fn totals(self: *OnCpu) !Totals {
        const ncpu: usize = @intCast(try sys.numPossibleCpus());
        const bytes = try self.gpa.alloc(u8, ncpu * @sizeOf(Slot));
        defer self.gpa.free(bytes);
        const key = std.mem.toBytes(@as(u32, 0));
        const is_state_exist = try self.maps.get(.oncpu_stack_state).map.lookup(&key, bytes);
        if (!is_state_exist) return error.NotFound;
        var out = Totals{};
        for (0..ncpu) |i| {
            const slot = std.mem.bytesToValue(Slot, bytes[i * @sizeOf(Slot) ..][0..@sizeOf(Slot)]);
            out.walks += slot.completed_walks;
            out.kernel_walks += slot.walks_from_kernel;
            out.sent += slot.records_sent;
            out.dropped += slot.records_dropped;
            out.repeats += slot.repeated_stacks;
            out.map_full += slot.count_map_insert_failures;
            for (slot.stop_reason_counts, 0..) |n, s| out.stops[s] += n;
        }
        return out;
    }

    pub fn get_unwind_maps(self: *OnCpu, comptime Modules: type, comptime ProcessEntry: type) !UnwindMaps(Modules, ProcessEntry) {
        var rows = self.maps.get(.unwind_rows).map;
        errdefer rows.deinit();

        var modules = self.maps.get(.unwind_modules).map;
        errdefer modules.deinit();

        var procs = self.maps.get(.unwind_procs).map;
        errdefer procs.deinit();

        return .{
            .rows = rows,
            .modules = try m.TypedMap(u32, Modules).init(modules),
            .processes = try m.TypedMap(u32, ProcessEntry).init(procs),
        };
    }

    pub fn UnwindMaps(comptime Modules: type, comptime ProcessEntry: type) type {
        return struct {
            rows: m.Map,
            modules: m.TypedMap(u32, Modules),
            processes: m.TypedMap(u32, ProcessEntry),

            const Self = @This();

            pub fn deinit(self: *Self) void {
                self.rows.deinit();
            }
        };
    }

    pub fn snapshot(self: *OnCpu, gpa: std.mem.Allocator, out: *std.ArrayList(CountEntry)) !void {
        const countsMap = self.maps.get(.oncpu_stack_counts).map;
        const counts = try m.TypedMap(CountKey, u64).init(countsMap);
        var prev: ?CountKey = null;
        while (try counts.nextKey(prev)) |key| {
            prev = key;
            if (try counts.lookup(key)) |count| {
                try out.append(gpa, .{ .key = key, .count = count });
            }
        }
    }

    pub fn deinit(self: *OnCpu) void {
        self.maps.deinit();
        self.loader.deinit();
        self.ring_buffer.deinit();
        self.* = undefined;
    }
};

test "init and deinit" {
    var o = OnCpu.init(std.testing.allocator) catch |err| switch (err) {
        error.PermissionDenied, error.NotSupported => return error.SkipZigTest,
        else => return err,
    };
    o.deinit();
}
