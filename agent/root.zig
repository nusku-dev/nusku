//! The agent: watches one process with eBPF and hands out a report of what it saw at every
//! interval. Reports carry raw addresses and the regions they resolve against; turning them
//! into symbols is the server's job, so the agent stays small on the machine it profiles.
//!
//! The layers, bottom up:
//!   os/       system calls: files, timers, poll, perf events, process descriptors
//!   bpf/      loading BPF objects and talking to their maps; kernel/ holds the programs
//!   target/   what is known about the target: its mappings, build IDs, files, the kernel
//!   unwind/   unwind tables built from .eh_frame and .gopclntab, mirrored into the kernel
//!   cpu/      the on-CPU metric: the sampler, its frame cache, and its windows
//!   symbols/  the binaries offered to the server, so it can name the addresses
//!   session.zig, profile.zig   one run: the metrics together, and the loop that drives them

const profile_file = @import("profile.zig");
const session_file = @import("session.zig");
const collector_file = @import("cpu/collector.zig");
const binary_file = @import("symbols/binary.zig");

pub const profile = profile_file.profile;
pub const Options = profile_file.Options;
pub const StopReason = profile_file.StopReason;
pub const Cancel = @import("os/cancel.zig").Cancel;

pub const Metric = session_file.Metric;
pub const Report = session_file.Report;
pub const Region = @import("target/regions.zig").Region;
pub const KernelIdentity = @import("target/kernel.zig").Identity;
pub const UnwindCoverage = @import("unwind/tables.zig").Coverage;
/// Why a mapping has no unwind table: the keys of `UnwindCoverage.unavailable`.
pub const UnwindCause = @import("unwind/registry.zig").Cause;

/// The on-CPU metric's part of a report.
pub const cpu = struct {
    pub const Window = collector_file.Window;
    pub const Stack = collector_file.Stack;
    pub const Loss = collector_file.Loss;
    pub const StopReason = collector_file.StopReason;
};

/// The binary stream: what a context with the four binary hooks receives (see `profile`).
pub const binary = struct {
    pub const Header = binary_file.Header;
    pub const Chunk = binary_file.Chunk;
    pub const Section = binary_file.Section;
};

/// A report copied out of the agent's buffers, owned: what a server keeps.
pub const Message = @import("message.zig").Message;

test {
    _ = @import("os/anonymous_memory.zig");
    _ = @import("os/cancel.zig");
    _ = @import("os/cpus.zig");
    _ = @import("os/perf_event.zig");
    _ = @import("os/pidfd.zig");
    _ = @import("os/poll.zig");
    _ = @import("os/process.zig");
    _ = @import("os/timer.zig");

    _ = @import("bpf/libbpf.zig");
    _ = @import("bpf/loader.zig");
    _ = @import("bpf/map.zig");
    _ = @import("bpf/object.zig");
    _ = @import("bpf/program.zig");
    _ = @import("bpf/ring_buffer.zig");

    _ = @import("target/build_id.zig");
    _ = @import("target/kernel.zig");
    _ = @import("target/mapped_file.zig");
    _ = @import("target/process_maps.zig");
    _ = @import("target/regions.zig");
    _ = @import("target/vdso.zig");

    _ = @import("unwind/cfi.zig");
    _ = @import("unwind/cfi_machine.zig");
    _ = @import("unwind/eh_frame.zig");
    _ = @import("unwind/elf_file.zig");
    _ = @import("unwind/go_pclntab.zig");
    _ = @import("unwind/module.zig");
    _ = @import("unwind/process_table.zig");
    _ = @import("unwind/registry.zig");
    _ = @import("unwind/table.zig");
    _ = @import("unwind/table_set.zig");
    _ = @import("unwind/tables.zig");

    _ = @import("cpu/collector.zig");
    _ = @import("cpu/frame_cache.zig");
    _ = @import("cpu/sampler.zig");
    _ = @import("cpu/window.zig");

    _ = binary_file;
    _ = @import("symbols/offer.zig");
    _ = @import("symbols/transfer.zig");
    _ = @import("symbols/vdso_symbols.zig");

    _ = @import("message.zig");

    _ = session_file;
    _ = profile_file;

    // Test-only code lives under testing/: end-to-end tests, and the child processes they run.
    _ = @import("testing/e2e/vdso_unwind.zig");
    _ = @import("testing/e2e/cpu_hotplug.zig");
    _ = @import("testing/e2e/go_unwind.zig");
    // The example of devlog Ep14, compiled with every test build so the guide cannot rot.
    _ = @import("testing/examples/server_feed.zig");
}
