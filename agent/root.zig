const std = @import("std");
const session = @import("sessions/session.zig");
const pro = @import("profile.zig");
const oncpu = @import("sessions/oncpu/oncpu.zig");
const unwind = @import("unwind/root.zig");

test {
    _ = oncpu;
    _ = session;
    _ = pro;
    _ = unwind;
}
