//! End to end: Go programs are unwound with their pclntab, frameless functions included.
//!
//! How: build testing/e2e/go/frameless.go with the Go toolchain, once as is and once stripped
//! (-s -w, as production images are). Its `leaf` has no frame: a frame-pointer walk from inside
//! it reads `middle`'s rbp and skips `middle`. The first test checks the rows built from the
//! pclntab, without root. The second profiles the running program and checks that every sample
//! in `leaf` has `middle` as its caller.
//!
//! Test-only, like everything under testing/. Skipped without a Go toolchain.

const std = @import("std");
const testing = std.testing;
const go_build = @import("../go_build.zig");
const child_process = @import("../process.zig");
const timer = @import("../../os/timer.zig");
const elf_file = @import("../../unwind/elf_file.zig");
const module = @import("../../unwind/module.zig");
const table = @import("../../unwind/table.zig");
const File = @import("../../os/file.zig").File;
const session_file = @import("../../session.zig");
const collector_file = @import("../../cpu/collector.zig");

const source = @embedFile("go/frameless.go");

/// The table of the binary at `path`, built as the agent builds it. A Go executable is not
/// position independent: it maps at the addresses written in it, so its bias is 0.
fn table_of(path: [:0]const u8, target: *table.Table) !module.Built {
    var file = try File.open(path);
    defer file.deinit();
    var loaded = try elf_file.load(&file);
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
    std.debug.print("go: {d} rows plain, {d} rows stripped\n", .{
        plain_table.rows.len, stripped_table.rows.len,
    });
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

    const session = try testing.allocator.create(session_file.Session);
    defer testing.allocator.destroy(session);
    try session.init(testing.allocator, .{
        .pid = child,
        .metrics = std.EnumSet(session_file.Metric).initOne(.cpu),
    });
    defer session.deinit(testing.allocator);

    var round: u32 = 0;
    while (round < 5) : (round += 1) {
        timer.sleep_ms(100);
        try session.tick();
    }
    const report = try session.report(testing.allocator);
    const window = report.cpu orelse return error.TestUnexpectedResult;

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
