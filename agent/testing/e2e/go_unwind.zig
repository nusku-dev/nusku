//! End to end: Go is unwound with its pclntab, stripped or not. go/frameless.go's `leaf` has no
//! frame, so a frame-pointer walk would skip `middle`; every sample in `leaf` must have
//! `middle` as its caller. Skipped without a Go toolchain.

const std = @import("std");
const testing = std.testing;
const go_build = @import("../go_build.zig");
const child_process = @import("../process.zig");
const timer = @import("../../os.zig").timer;
const elf_file = @import("../../elf.zig").file;
const module = @import("../../unwind/module.zig");
const table = @import("../../unwind/table.zig");
const File = @import("shared").File;
const Target = @import("../../target.zig").Target;
const Ebpf = @import("../../ebpf.zig").Ebpf;
const collector_file = @import("../../ebpf/cpu/collector.zig");
const build_id = @import("../../target/build_id.zig");

const source = @embedFile("go/frameless.go");

/// The table of the binary at `path`, built as the agent builds it. A Go executable is not
/// position independent: it maps at the addresses written in it, so its bias is 0.
fn table_of(path: [:0]const u8, target: *table.Table) !module.Built {
    var file = try File.open(path);
    defer file.deinit();
    var loaded = try elf_file.load(&file, &elf_file.sections_unwind, elf_file.file_size_max);
    defer loaded.deinit();
    // Its text segment is mapped at file offset 0x1000, at 0x401000: as /proc/<pid>/maps says.
    return module.table_build(target, testing.allocator, .{
        .file = loaded.bytes,
        .start = 0x401000,
        .end = 0x401000 + 0x1000,
        .offset = 0x1000,
    });
}

test "a Go binary's table comes from its pclntab, stripped or not, frameless functions too" {
    var plain = (try go_build.build(testing.allocator, source, "")) orelse return error.SkipZigTest;
    defer plain.deinit(testing.allocator);
    var stripped = (try go_build.build(testing.allocator, source, "-s -w")).?;
    defer stripped.deinit(testing.allocator);

    var plain_table: table.Table = undefined;
    const built = try table_of(plain.binary, &plain_table);
    defer plain_table.deinit(testing.allocator);
    try testing.expectEqual(module.Source.go_pclntab, built.source);
    try testing.expectEqual(@as(u64, 0), built.bias);

    var stripped_table: table.Table = undefined;
    _ = try table_of(stripped.binary, &stripped_table);
    defer stripped_table.deinit(testing.allocator);
    // Stripping removes symbols and DWARF, never the pclntab: the rows are the same.
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(plain_table.rows),
        std.mem.sliceAsBytes(stripped_table.rows),
    );

    const file = try go_build.file_read_whole(testing.allocator, plain.binary);
    defer testing.allocator.free(file);
    const leaf = (try go_build.symbol_range(file, "main.leaf")).?;
    const middle = (try go_build.symbol_range(file, "main.middle")).?;

    // leaf never moves rsp: everywhere, the return address is right at rsp.
    var address = leaf.start;
    while (address < leaf.end) : (address += 1) {
        const row = plain_table.find(address) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@intFromEnum(table.CfaType.rsp), row.cfa_type);
        try testing.expectEqual(@as(i32, 8), row.cfa_offset);
    }
    // middle pushes rbp: after that, rbp is saved right below the return address.
    var saved_rows: u32 = 0;
    address = middle.start;
    while (address < middle.end) : (address += 1) {
        const row = plain_table.find(address) orelse return error.TestUnexpectedResult;
        if (row.rbp_type == @intFromEnum(table.RbpType.saved)) {
            try testing.expectEqual(@as(i16, -16), row.rbp_offset);
            saved_rows += 1;
        }
    }
    try testing.expect(saved_rows > 0);
}

test "a Go binary has a build ID, though its note segment leaves it out" {
    var plain = (try go_build.build(testing.allocator, source, "")) orelse return error.SkipZigTest;
    defer plain.deinit(testing.allocator);

    var file = try File.open(plain.binary);
    defer file.deinit();
    var prefix: [build_id.prefix_size]u8 = undefined;
    // Go's note segment holds only Go's own note: the program headers do not lead to the ID.
    const prefix_read = try file.read_at(&prefix, 0);
    try testing.expect(build_id.from_prefix(prefix[0..prefix_read]) == null);
    const id = build_id.from_file(&file, &prefix) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 20), id.len); // SHA-1, as Go writes it.
}

test "a running Go program: the caller of a frameless function is found (needs root)" {
    if (std.os.linux.geteuid() != 0) return error.SkipZigTest;
    var plain = (try go_build.build(testing.allocator, source, "")) orelse return error.SkipZigTest;
    defer plain.deinit(testing.allocator);

    const file = try go_build.file_read_whole(testing.allocator, plain.binary);
    defer testing.allocator.free(file);
    const leaf = (try go_build.symbol_range(file, "main.leaf")).?;
    const middle = (try go_build.symbol_range(file, "main.middle")).?;

    const child = try go_build.spawn(plain.binary);
    defer child_process.child_reap(child);
    timer.sleep_ms(50); // Long enough for exec: the maps must show the Go binary, not our fork.

    var target = try Target.init(testing.allocator, child);
    defer target.deinit(testing.allocator);
    const ebpf = try testing.allocator.create(Ebpf);
    defer testing.allocator.destroy(ebpf);
    try ebpf.init(testing.allocator, &target, .{ .metrics = .initOne(.cpu) });
    defer ebpf.deinit(testing.allocator);

    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        timer.sleep_ms(100);
        try ebpf.tick(testing.allocator, &target);
    }
    const windows = try ebpf.collect(testing.allocator, &target);
    const window = windows.cpu orelse return error.TestUnexpectedResult;

    var leaf_samples: u64 = 0;
    var leaf_samples_called_by_middle: u64 = 0;
    for (window.stacks) |stack| {
        if (stack.user.len < 2) continue;
        if (stack.user[0] < leaf.start or stack.user[0] >= leaf.end) continue;
        leaf_samples += stack.samples;
        // Return addresses point after the call: look one byte back, inside the call.
        const caller = stack.user[1] - 1;
        if (caller < middle.start or caller >= middle.end) continue;
        leaf_samples_called_by_middle += stack.samples;
    }
    const complete = window.stops[@intFromEnum(collector_file.StopReason.end)];
    std.debug.print("go e2e: {d} samples, {d} complete, {d} in leaf, {d} of those from middle\n", .{
        window.samples, complete, leaf_samples, leaf_samples_called_by_middle,
    });

    try testing.expect(leaf_samples > 0);
    try testing.expect(leaf_samples_called_by_middle * 10 >= leaf_samples * 9);
    // A goroutine's stack ends at runtime.goexit, which the pclntab marks as the top frame.
    try testing.expect(complete * 10 >= window.samples * 9);
}
