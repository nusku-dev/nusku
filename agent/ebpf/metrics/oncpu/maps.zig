const std = @import("std");

const l = @import("../../loader/loader.zig");

const MapName = enum {
    target_pid,
    unwind_rows,
    unwind_modules,
    unwind_procs,
    oncpu_stack_state,
    oncpu_stack_continuations,
    oncpu_stack_counts,
    sample_ring_buffer,

    fn key(self: MapName) [:0]const u8 {
        return @tagName(self);
    }
};

const MAP_COUNT = @typeInfo(MapName).@"enum".fields.len;

pub const Maps = struct {
    maps: std.AutoHashMap(MapName, l.MapRef),

    pub fn init(allocator: std.mem.Allocator, loader: l.Loader) l.Error!Maps {
        var maps = std.AutoHashMap(MapName, l.MapRef).init(allocator);

        inline for (@typeInfo(MapName).@"enum".fields) |field| {
            const name: MapName = @enumFromInt(field.value);
            var map = try loader.createMap(name.key());
            errdefer map.map.deinit();
            try maps.put(name, map);
        }
        return Maps{ .maps = maps };
    }

    pub fn get(self: Maps, map_name: MapName) l.MapRef {
        return self.maps.get(map_name) orelse unreachable;
    }

    pub fn list(self: Maps) [MAP_COUNT]l.MapRef {
        var res: [MAP_COUNT]l.MapRef = undefined;
        var iter = self.maps.valueIterator();

        for (&res) |*item| {
            item.* = iter.next().?.*;
        }

        return res;
    }

    pub fn deinit(self: *Maps) void {
        var it = self.maps.valueIterator();
        while (it.next()) |map| {
            map.map.deinit();
        }
        self.maps.deinit();
    }
};
