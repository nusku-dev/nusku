const std = @import("std");

const onCpu = @import("metrics/oncpu/oncpu.zig");

pub const OnCpu = onCpu.OnCpu;
pub const CountEntry = onCpu.CountEntry;

test "BPF object file exists and is not empty" {
    const oncpu_bpf_bytes = @embedFile("oncpu_bpf");
    try std.testing.expect(oncpu_bpf_bytes.len > 0);
}

test {
    _ = onCpu;
    _ = @import("kernel/oncpu_test.zig");
    _ = @import("loader/loader.zig");
    _ = @import("metrics/oncpu/ring_buffer.zig");
    _ = @import("metrics/oncpu/maps.zig");
}
