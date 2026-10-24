const std = @import("std");
const ELF = @import("../elf/parser.zig").ELF;

test "elf must contains perf_event" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event");
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
        .{ .name = "stacks", .def = .{ .map_type = 7, .key_size = 4, .value_size = 127 * 8, .max_entries = 16384 } },
        .{ .name = "counts", .def = .{ .map_type = 1, .key_size = 12, .value_size = 8, .max_entries = 16384 } },
        .{ .name = "target_pid", .def = .{ .map_type = 2, .key_size = 4, .value_size = 4, .max_entries = 1 } },
        .{ .name = "regs_debug", .def = .{ .map_type = 2, .key_size = 4, .value_size = 64, .max_entries = 256 } },
        .{ .name = "unwind_rows", .def = .{ .map_type = 2, .key_size = 4, .value_size = 262144 * 12, .max_entries = 1 } },
        .{ .name = "unwind_modules", .def = .{ .map_type = 2, .key_size = 4, .value_size = 24, .max_entries = 256 } },
        .{ .name = "unwind_procs", .def = .{ .map_type = 1, .key_size = 4, .value_size = 4104, .max_entries = 1024 } },
        .{ .name = "lookup_debug", .def = .{ .map_type = 2, .key_size = 4, .value_size = 128, .max_entries = 256 } },
        .{ .name = "frame_trace_stats", .def = .{ .map_type = 2, .key_size = 4, .value_size = 624, .max_entries = 256 } },
        .{ .name = "tail_call_programs", .def = .{ .map_type = 3, .key_size = 4, .value_size = 4, .max_entries = 1 } },
        .{ .name = "tail_call_stats", .def = .{ .map_type = 2, .key_size = 4, .value_size = 40, .max_entries = 256 } },
        .{ .name = "stack_walk_programs", .def = .{ .map_type = 3, .key_size = 4, .value_size = 4, .max_entries = 1 } },
        .{ .name = "stack_walk_states", .def = .{ .map_type = 2, .key_size = 4, .value_size = 17680, .max_entries = 256 } },
        .{ .name = "sample_ring_buffer", .def = .{ .map_type = 27, .key_size = 0, .value_size = 0, .max_entries = 256 * 1024 } },
        .{ .name = "ring_buffer_cpu_stats", .def = .{ .map_type = 2, .key_size = 4, .value_size = 24, .max_entries = 256 } },
        .{ .name = "oncpu_stack_continuations", .def = .{ .map_type = 2, .key_size = 4, .value_size = 4, .max_entries = 1 } },
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
    const program = try elf.findSection("perf_event");
    const code = try elf.readSectionData(program);
    const maps = try elf.findSection(".maps");

    // There are three map definitions, each 16 bytes.
    const map_count = 18;
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

    const profiler_maps = [_][]const u8{ "counts", "stacks", "target_pid" };

    const probe_maps = [_][]const u8{
        "regs_debug",
        "unwind_rows",
        "unwind_modules",
        "unwind_procs",
        "lookup_debug",
        "frame_trace_stats",
        "tail_call_programs",
        "tail_call_stats",
        "stack_walk_programs",
        "stack_walk_states",
        "sample_ring_buffer",
        "ring_buffer_cpu_stats",
        "oncpu_stack_state",
        "oncpu_stack_continuations",
    };

    for (profiler_maps) |name| {
        try std.testing.expect(seen[(try elf.findSymbol(name)).value / map_size]);
    }
    for (probe_maps) |name| {
        try std.testing.expect(!seen[(try elf.findSymbol(name)).value / map_size]);
    }
}

// --- onCpusample test ---
test "elf must contains on_cpu_sample" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event");
    const func = try elf.findSymbol("onCpusample");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the program only calls the kernel helpers we use, directly" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event"));

    // Instruction layout: opcode u8, registers u8 (src in the high nibble), offset i16, imm i32.
    var seen: u64 = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        const opcode = code[i];
        if (opcode == 0x8d) return error.IndirectCall; // callx: the verifier would reject it
        if (opcode != 0x85) continue; // not a call

        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4); // 0 = kernel helper
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 2, 14, 27 => seen |= @as(u64, 1) << @intCast(helper),
            else => return error.UnexpectedHelper,
        }
    }
    // map_lookup_elem, map_update_elem, get_current_pid_tgid, get_stackid
    try std.testing.expectEqual((1 << 1) | (1 << 2) | (1 << 14) | (1 << 27), seen);
}

// --- readRegisters test ---
test "elf must contains readRegisters" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/regs");
    const func = try elf.findSymbol("readRegisters");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the readRegisters calls only the helpers we expect" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event/regs"));

    var seen = std.StaticBitSet(256).initEmpty();
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        if (code[i] == 0x8d) return error.IndirectCall;
        if (code[i] != 0x85) continue;
        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 8, 14, 158, 175 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
            else => return error.UnexpectedHelper,
        }
    }
    try std.testing.expectEqual(@as(usize, 5), seen.count());
}

// --- findUnwindTable test ---
test "elf must contains findUnwindTable" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/lookup");
    const func = try elf.findSymbol("findUnwindTable");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the findUnwindRow calls only the helpers we expect" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event/lookup"));

    var seen = std.StaticBitSet(256).initEmpty();
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        if (code[i] == 0x8d) return error.IndirectCall;
        if (code[i] != 0x85) continue;
        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 8, 14, 158, 175 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
            else => return error.UnexpectedHelper,
        }
    }
    try std.testing.expectEqual(@as(usize, 5), seen.count());
}

// --- traceFrame test ---
test "elf must contains traceFrame" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/step");
    const func = try elf.findSymbol("traceFrame");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the traceFrame calls only the helpers we expect" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event/step"));

    var seen = std.StaticBitSet(256).initEmpty();
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        if (code[i] == 0x8d) return error.IndirectCall;
        if (code[i] != 0x85) continue;
        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 8, 14, 158, 175, 112 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
            else => return error.UnexpectedHelper,
        }
    }
    try std.testing.expectEqual(@as(usize, 6), seen.count());
}

// --- measureTailCallDepth test ---
test "elf must contains measureTailCallDepth" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/chain");
    const func = try elf.findSymbol("measureTailCallDepth");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the measureTailCallDepth calls only the helpers we expect" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event/chain"));

    var seen = std.StaticBitSet(256).initEmpty();
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        if (code[i] == 0x8d) return error.IndirectCall;
        if (code[i] != 0x85) continue;
        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 8, 12, 14 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
            else => return error.UnexpectedHelper,
        }
    }
    try std.testing.expectEqual(@as(usize, 4), seen.count());
}

// --- startOrContinueStackWalk test ---
test "elf must contains startOrContinueStackWalk" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const perf_event = try elf.findSection("perf_event/walk");
    const func = try elf.findSymbol("startOrContinueStackWalk");

    const data = try elf.readSectionData(perf_event);

    try std.testing.expectEqual(perf_event.index, func.section);
    try std.testing.expectEqual(data.len, func.size);
}

test "the startOrContinueStackWalk calls only the helpers we expect" {
    const elf = try ELF.init(@embedFile("oncpu_bpf"));
    const code = try elf.readSectionData(try elf.findSection("perf_event/walk"));

    var seen = std.StaticBitSet(256).initEmpty();
    var i: usize = 0;
    while (i < code.len) : (i += 8) {
        if (code[i] == 0x8d) return error.IndirectCall;
        if (code[i] != 0x85) continue;
        try std.testing.expectEqual(@as(u8, 0), code[i + 1] >> 4);
        const helper = std.mem.readInt(i32, code[i + 4 ..][0..4], .little);
        switch (helper) {
            1, 8, 12, 14, 112, 158, 175 => seen.set(@intCast(helper)), // lookup, cpu id, pid_tgid, task_btf, pt_regs
            else => return error.UnexpectedHelper,
        }
    }
    try std.testing.expectEqual(@as(usize, 7), seen.count());
}
