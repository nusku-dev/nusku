const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;

test "elf must contains perf_event" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/oncpu_walk");
    const data = try elf.readSectionData(perf_event);
    try std.testing.expect(data.len > 16 and data.len % 8 == 0); // whole 8-byte instruction
}

test "elf must contains License" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const license = try elf.findSection("license");
    const data = try elf.readSectionData(license);
    try std.testing.expectEqualStrings("GPL", std.mem.sliceTo(data, 0));
}

// -- maps --
test "map definitions can be read straight from the object" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const maps = try elf.findSection(".maps");
    const bytes = try elf.readSectionData(maps);

    const Def = struct { map_type: u32, key_size: u32, value_size: u32, max_entries: u32 };
    const expected = [_]struct { name: []const u8, def: Def }{
        .{ .name = "target_pid", .def = .{ .map_type = 2, .key_size = 4, .value_size = 4, .max_entries = 1 } },
        .{ .name = "unwind_rows", .def = .{ .map_type = 2, .key_size = 4, .value_size = 262144 * 12, .max_entries = 1 } },
        .{ .name = "unwind_modules", .def = .{ .map_type = 2, .key_size = 4, .value_size = 24, .max_entries = 256 } },
        .{ .name = "unwind_procs", .def = .{ .map_type = 1, .key_size = 4, .value_size = 4104, .max_entries = 1024 } },
        .{ .name = "sample_ring_buffer", .def = .{ .map_type = 27, .key_size = 0, .value_size = 0, .max_entries = 256 * 1024 } },
        .{ .name = "oncpu_stack_continuations", .def = .{ .map_type = 3, .key_size = 4, .value_size = 4, .max_entries = 1 } },
        .{ .name = "oncpu_stack_state", .def = .{ .map_type = 6, .key_size = 4, .value_size = 1544, .max_entries = 1 } },
        .{ .name = "oncpu_stack_counts", .def = .{ .map_type = 1, .key_size = 16, .value_size = 8, .max_entries = 8192 } },
    };

    for (expected) |e| {
        const sym = try elf.findSymbol(e.name);
        try std.testing.expectEqual(maps.index, sym.section);
        try std.testing.expectEqual(@as(usize, 16), sym.size);

        const raw = bytes[sym.value..][0..16];
        try std.testing.expectEqual(e.def.map_type, std.mem.readInt(u32, raw[0..4], .little));
        try std.testing.expectEqual(e.def.key_size, std.mem.readInt(u32, raw[4..8], .little));
        try std.testing.expectEqual(e.def.value_size, std.mem.readInt(u32, raw[8..12], .little));
        try std.testing.expectEqual(e.def.max_entries, std.mem.readInt(u32, raw[12..16], .little));
    }
}

test "map relocations in the program reference all maps" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const program = try elf.findSection("perf_event/oncpu_walk");
    const code = try elf.readSectionData(program);
    const maps = try elf.findSection(".maps");

    // There are three map definitions, each 16 bytes.
    const map_count = 8;
    std.debug.assert(maps.size == map_count * 16);

    const map_size = 16;
    var seen = [_]bool{false} ** map_count;

    var it = try elf.relocationsFor(program);

    while (try it.next()) |reloc| {
        // Every relocation must be a map reference. Anything else (such as .rodata
        // constants) needs loader support we don't have, so the program must not use it.
        try std.testing.expectEqual(maps.index, reloc.target.section);

        // Map references use R_BPF_64_64.
        try std.testing.expectEqual(@as(u32, 1), reloc.kind);

        // A map relocation points at the first instruction of an
        // ld_imm64 pair.
        try std.testing.expect(reloc.offset + 16 <= code.len);
        try std.testing.expectEqual(@as(u8, 0x18), code[reloc.offset]);

        // For R_BPF_64_64 against the .maps section symbol, the
        // relocation addend is represented by the immediate value
        // already present in the first instruction.
        const map_offset = std.mem.readInt(
            i32,
            code[reloc.offset + 4 ..][0..4],
            .little,
        );

        try std.testing.expect(map_offset >= 0);

        const offset = @as(usize, @intCast(map_offset));

        // Every map definition occupies 16 bytes in .maps.
        try std.testing.expect(offset % map_size == 0);
        try std.testing.expect(offset + map_size <= maps.size);

        const map_index = offset / map_size;
        try std.testing.expect(map_index < map_count);

        seen[map_index] = true;
    }

    const profiler_maps = [_][]const u8{
        "target_pid",         "unwind_rows",
        "unwind_modules",     "unwind_procs",
        "oncpu_stack_state",  "oncpu_stack_continuations",
        "oncpu_stack_counts", "sample_ring_buffer",
    };

    for (profiler_maps) |name| {
        try std.testing.expect(seen[(try elf.findSymbol(name)).value / map_size]);
    }
}

// --- readRegisters test ---
// test "elf must contains readRegisters" {
//     const elf = try ELF.init(@embedFile("oncpu_bpf"));
//     const perf_event = try elf.findSection("perf_event/regs");
//     const func = try elf.findSymbol("readRegisters");

//     const data = try elf.readSectionData(perf_event);

//     try std.testing.expectEqual(perf_event.index, func.section);
//     try std.testing.expectEqual(data.len, func.size);
// }

// test "the readRegisters calls only the helpers we expect" {
//     const elf = try ELF.init(@embedFile("oncpu_bpf"));
//     const code = try elf.readSectionData(try elf.findSection("perf_event/regs"));

//     var seen = std.StaticBitSet(256).initEmpty();
//     var i: usize = 0;
//     while (i < code.len) : (i += 8) {
//         if (code[i] == 0x8d) return error.IndirectCall;
//         if (code[i] != 0x85) continue;
//         try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
//         const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
//         switch (helper) {
//             1, 8, 14, 158, 175 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
//             else => return error.UnexpectedHelper,
//         }
//     }
//     try std.testing.expectEqual(@as(usize, 5), seen.count());
// }
