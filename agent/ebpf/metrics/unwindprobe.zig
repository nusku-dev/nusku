//! Harness for the BPF unwinder's probe programs: loads one program with the table maps,
//! hands out the table maps, and reads its per-CPU debug slots.
const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;
const l = @import("../loader/loader.zig");
const sys = @import("../libc/sys.zig");
const perf = @import("../event.zig");
const TypedMap = @import("../loader/map.zig").TypedMap;
const tablemaps = @import("../loader/tablemaps.zig");

pub const max_cpus = 256;
pub const max_frames = 128;
pub const step_words = 64;
pub const snapshot_words = 2048;

pub const LookupSlot = extern struct {
    samples: u64,
    no_process: u64,
    no_mapping: u64,
    no_table: u64,
    no_row: u64,
    found: u64,
    found_ip: u64,
    found_module: u64,
    found_file_addr: u64,
    row_pc: u64,
    row_cfa_type: u64,
    row_cfa_offset: i64,
    row_rbp_type: u64,
    row_rbp_offset: i64,
    mapping_steps: u64,
    row_steps: u64,
};

pub const StepSlot = extern struct {
    samples: u64,
    no_row: u64,
    ok: u64,
    ended: u64,
    failed: u64,
    ip: u64,
    sp: u64,
    bp: u64,
    module: u64,
    file_addr: u64,
    caller_pc: u64,
    caller_sp: u64,
    caller_bp: u64,
    snapshot_ok: u64,
    stack: [step_words]u64,
};

pub const WalkSlot = extern struct {
    active: u64,
    walks: u64,
    kernel_walks: u64,
    pc: u64,
    sp: u64,
    bp: u64,
    first: u64,
    fp_steps: u64,
    start_pc: u64,
    start_sp: u64,
    start_bp: u64,
    kernel: u64,
    leaf_is_return: u64,
    code_before: u64,
    snapshot_len: u64,
    count: u64,
    stop: u64,
    hash: u64,
    stops: [16]u64,
    frames: [max_frames]u64,
    snapshot: [snapshot_words]u64,
};

comptime {
    if (@sizeOf(WalkSlot) != 17680) @compileError("WalkSlot size changed: update oncpu.ebpf.zig too");
}

fn Probe(
    comptime Slot: type,
    comptime section: []const u8,
    comptime function: [:0]const u8,
    comptime debug_map: [:0]const u8,
    comptime prog_map: ?[:0]const u8,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        loader: l.Loader,
        target: l.MapRef,
        rows: l.MapRef,
        modules: l.MapRef,
        procs: l.MapRef,
        debug: l.MapRef,
        progs: ?l.MapRef,
        slots: TypedMap(u32, Slot),
        program_fd: c_int,
        events: []perf.Event,
        attached: usize,

        /// Creates the maps and loads the program. Nothing is sampled until `begin`.
        pub fn init(allocator: std.mem.Allocator) !Self {
            const elf = try ELF.init(@embedFile("oncpu_bpf"));
            var loader = l.Loader.init(allocator, elf);
            errdefer loader.deinit();
            var target = try loader.createMap("target_pid");
            errdefer target.map.deinit();
            var rows = try loader.createMap("unwind_rows");
            errdefer rows.map.deinit();
            var modules = try loader.createMap("unwind_modules");
            errdefer modules.map.deinit();
            var procs = try loader.createMap("unwind_procs");
            errdefer procs.map.deinit();
            var debug = try loader.createMap(debug_map);
            errdefer debug.map.deinit();
            var progs: ?l.MapRef = null;
            errdefer if (progs) |*p| p.map.deinit();
            if (prog_map) |name| progs = try loader.createMap(name);

            var maps: [6]l.MapRef = .{ target, rows, modules, procs, debug, debug };
            var map_count: usize = 5;
            if (progs) |p| {
                maps[5] = p;
                map_count = 6;
            }
            const program_fd = try loader.load(.perf_event, section, function, maps[0..map_count]);

            // A program that jumps to itself finds itself in slot 0.
            if (progs) |*p| {
                const index = std.mem.toBytes(@as(u32, 0));
                const value = std.mem.toBytes(@as(u32, @intCast(program_fd)));
                try p.map.update(&index, &value);
            }

            return .{
                .allocator = allocator,
                .loader = loader,
                .target = target,
                .rows = rows,
                .modules = modules,
                .procs = procs,
                .debug = debug,
                .progs = progs,
                .slots = try TypedMap(u32, Slot).init(debug.map),
                .program_fd = program_fd,
                .events = &.{},
                .attached = 0,
            };
        }

        /// The table maps, for `writeModulesFrom` and `writeProcess`. The maps stay owned by
        /// the probe; the caller calls `deinit` on the result to free its row image.
        pub fn tables(self: *Self) !tablemaps.TableMaps {
            return tablemaps.TableMaps.wrap(self.allocator, self.rows.map, self.modules.map, self.procs.map);
        }

        /// Samples of `pid` are recorded from now on (0 stops recording).
        pub fn setTarget(self: *Self, pid: u32) !void {
            const slotTarget = std.mem.toBytes(@as(u32, 0));
            const value = std.mem.toBytes(pid);
            try self.target.map.update(&slotTarget, &value);
        }

        /// Starts sampling `pid` at `hz` on every CPU.
        pub fn begin(self: *Self, pid: u32, hz: u32) !void {
            try self.setTarget(pid);
            const ncpu = try sys.numPossibleCpus();
            const events = try self.allocator.alloc(perf.Event, ncpu);
            errdefer self.allocator.free(events);
            var attached: usize = 0;
            errdefer for (events[0..attached]) |*e| e.deinit();
            var cpu: u32 = 0;
            while (cpu < ncpu) : (cpu += 1) {
                var event = perf.Event.openCpuClock(cpu, hz) catch |err| switch (err) {
                    error.CpuOffline => continue,
                    else => return err,
                };
                errdefer event.deinit();
                try event.attach(self.program_fd);
                try event.enable();
                events[attached] = event;
                attached += 1;
            }
            self.events = events;
            self.attached = attached;
        }

        /// Stops recording samples, so the slots can be read while no CPU writes to one.
        pub fn pause(self: *Self) !void {
            try self.setTarget(0);
            sys.sleepMs(5);
        }

        pub fn slot(self: *Self, cpu: u32) !Slot {
            return (try self.slots.lookup(cpu)) orelse error.NotFound;
        }

        pub fn deinit(self: *Self) void {
            for (self.events[0..self.attached]) |*e| e.deinit();
            if (self.events.len > 0) self.allocator.free(self.events);
            self.loader.deinit();
            self.target.map.deinit();
            self.rows.map.deinit();
            self.modules.map.deinit();
            self.procs.map.deinit();
            self.debug.map.deinit();
            if (self.progs) |*p| p.map.deinit();
        }
    };
}

pub const LookupProbe = Probe(LookupSlot, "perf_event/lookup", "lookupProbe", "lookup_debug", null);
pub const StepProbe = Probe(StepSlot, "perf_event/step", "stepProbe", "step_debug", null);
pub const WalkProbe = Probe(WalkSlot, "perf_event/walk", "walkProbe", "walk_debug", "walk_progs");
