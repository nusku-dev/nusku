//! The agent: profiles a process with eBPF, and watches the processes of the machine. Two
//! things to use, each pulled one event at a time:
//!
//!     var run = try agent.Run.init(gpa, .{ .pid = pid });
//!     defer run.deinit();
//!     while (try run.next()) |event| switch (event) { ... };
//!
//!     var watch = try agent.Watch.init(gpa, .{});
//!     defer watch.deinit();
//!     while (try watch.next()) |event| switch (event) { ... };
//!
//! `stop` ends either from another thread or a signal handler. What they give is in
//! shared/protocol.
//!
//! The layers, bottom up. Each is a file and a folder of the same name; the file is the one
//! struct, or for a toolbox the few tools, that the layers above may import. A layer imports only
//! the layers below it, and never one beside it:
//!   os         system calls: files, timers, poll, perf events, process descriptors
//!   elf        reading ELF files: their sections, .eh_frame
//!   target     Target: the process profiled, its regions, its kernel, its vDSO
//!   unwind     Unwind: tables of where each frame's caller is, built from the binaries
//!   ebpf       Ebpf: the programs in the kernel, and what they measure (on-CPU today)
//!   symbols    Symbols: the binaries offered to the server, so it can name the addresses
//!   processes  Processes: what /proc says about every process
//! Above them, the parent: run.zig (target, ebpf and symbols together) and watch.zig
//! (processes), with message.zig making the protocol's messages.

const run_file = @import("run.zig");
const watch_file = @import("watch.zig");

pub const Run = run_file.Run;
pub const RunOptions = run_file.Options;
pub const RunEvent = run_file.Event;

pub const Watch = watch_file.Watch;
pub const WatchOptions = watch_file.Options;
pub const WatchEvent = watch_file.Event;

test {
    _ = @import("os.zig");
    _ = @import("elf.zig");
    _ = @import("target.zig");
    _ = @import("unwind.zig");
    _ = @import("ebpf.zig");
    _ = @import("symbols.zig");
    _ = @import("processes.zig");

    _ = @import("message.zig");
    _ = run_file;
    _ = watch_file;

    _ = @import("testing/layers.zig");
    _ = @import("testing/e2e/vdso_unwind.zig");
    _ = @import("testing/e2e/cpu_hotplug.zig");
    _ = @import("testing/e2e/go_unwind.zig");
    _ = @import("testing/e2e/watch_processes.zig");
    _ = @import("testing/examples/server_feed.zig");
}
