const std = @import("std");
const oncpu_test = @import("kernel/oncpu_test.zig");
const loader = @import("loader/loader.zig");

test "BPF object file exists and is not empty" {
    const oncpu_bpf_bytes = @embedFile("oncpu_bpf");
    try std.testing.expect(oncpu_bpf_bytes.len > 0);
}

test {
    _ = oncpu_test;
    _ = loader;
}
