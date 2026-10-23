const std = @import("std");
const oncpu_test = @import("kernel/oncpu_test.zig");
const loader = @import("loader/loader.zig");
const regsprobe = @import("metrics/regsprobe.zig");
pub const unwindprobe = @import("metrics/unwindprobe.zig");
pub const tablemaps = @import("loader/tablemaps.zig");
pub const chainprobe = @import("metrics/chainprobe.zig");
pub const oncpu = @import("metrics/oncpu.zig");
pub const ringprobe = @import("metrics/ringprobe.zig");
pub const oncpuprobe = @import("metrics/oncpuprobe.zig");

test "BPF object file exists and is not empty" {
    const oncpu_bpf_bytes = @embedFile("oncpu_bpf");
    try std.testing.expect(oncpu_bpf_bytes.len > 0);
}

test {
    _ = oncpu_test;
    _ = loader;
    _ = oncpu;
    _ = tablemaps;
    _ = regsprobe;
    _ = unwindprobe;
    _ = chainprobe;
    _ = ringprobe;
    _ = oncpuprobe;
}
