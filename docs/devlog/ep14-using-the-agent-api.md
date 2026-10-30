---
date: 2026-10-31
---

# Ep14: Using the Agent's API

The agent is a library. The CLI uses it today, and the server will use it next: it will start
profiles with options, listen to the data in real time, and later turn the addresses into
function names with a symbolizer. This episode is the guide for that: what to call, what comes
back, how long it lives, and how to get from an address to a name.

The short version:

> One call, `profile`, runs a profile and calls you back once per interval with a `Report`.
> Copy what you need inside the callback. Addresses in the report resolve against the regions
> that come with it.

Everything here is in `agent/root.zig`. The example in section 8 is real code
(`agent/testing/examples/server_feed.zig`), compiled with every test build, so this guide
cannot drift away from the code without a test failing.

## 1. The whole API in one call

```zig
const agent = @import("agent");

pub fn profile(
    gpa: std.mem.Allocator,
    options: agent.Options,
    context: anytype,              // a pointer to your state: &my_state
    comptime on_report: anytype,   // fn (*MyState, *const agent.Report) !void
) !agent.StopReason
```

`profile` blocks its thread from start to finish:

```
 profile(...)
   │  load the BPF program, build unwind tables, start sampling
   │
   ├─► on_report(context, &report)     every interval_ms
   ├─► on_report(context, &report)
   │   ...
   ├─► on_report(context, &report)     once more: the last, partial window
   │
   └─ returns why it stopped: .duration, .target_exited or .cancelled
```

It releases everything it loaded into the kernel before it returns, on success and on error.

Starting takes a moment: the program is loaded and the unwind tables of the target's binaries
are built (hundreds of milliseconds for a large binary). The clock of the run starts after
that: the first report comes one whole `interval_ms` after sampling began, and `duration_s`
counts from there too.

## 2. Options

```zig
pub const Options = struct {
    pid: u32,                              // the process to profile
    metrics: std.EnumSet(agent.Metric),    // .cpu today; offcpu, mem, io, net, locks, sched later
    interval_ms: u32,                      // how often a report comes
    duration_s: u32,                       // 0: until the target exits or the run is cancelled
    cancel: ?*const agent.Cancel = null,   // stops the run from another thread
};
```

Asking for a metric that does not exist yet fails at once with `error.MetricNotImplemented`,
before anything is loaded. So the server can send the options it wants, and learn right away
what this agent supports.

## 3. The report

One report per interval. A window is independent: its numbers are what happened **during**
the window, not a running total. A server that wants a total adds windows up.

```
Report
├── start_unix_ns, duration_ns   when the window began (wall clock) and how long it was
├── pid
├── regions: []Region            the target's executable mappings, to resolve addresses
├── kernel: KernelIdentity       release, build ID, address of _text: to resolve kernel frames
├── unwind: UnwindCoverage       how much of the target's code has unwind tables, and why not
└── cpu: ?cpu.Window             null if the cpu metric was not asked for
    ├── sample_hz                samples per second per CPU
    ├── samples                  the window's samples (= the sum over stacks)
    ├── stacks: []cpu.Stack      most samples first
    │   ├── samples
    │   ├── user: []u64          addresses, innermost first
    │   ├── kernel: []u64        kernel addresses, innermost first (empty in user mode)
    │   ├── stop: cpu.StopReason why the walk ended: .end means complete
    │   ├── leaf_is_return       user[0] is a return address (the sample was in a syscall)
    │   └── kernel_truncated     the kernel stack had more frames than were kept
    ├── stops: [16]u64           the window's samples by stop reason
    └── loss: cpu.Loss           samples the window misses, by reason
```

Three rules make the numbers easy to trust:

- **Units.** `samples / sample_hz` is CPU seconds. At 99 Hz, 99 samples of a stack is one second
  of one CPU spent in it.
- **Nothing is missing silently.** Every sample is in `samples`, or in one of `loss`'s counters
  (`ring_full`, `counts_full`, `frames_missing`, ...). `records_malformed` and
  `walks_abandoned` should always be 0: they would be bugs, and are counted so they show.
- **Every cut stack says why.** `stops` adds up to `samples`. A UI can show "92% complete
  stacks; 6% cut in a binary without a table; 2% stack read failed".

`unwind` explains most cut stacks: `unavailable` counts the target's mappings without a
table by `agent.UnwindCause` (`.no_unwind_info`, `.wrong_file`, `.vdso_unknown`, ...), and
`mappings_dropped` counts the mappings that did not fit.

## 4. Lifetime: copy inside the callback

The report points into the agent's own buffers: the stacks into its frame cache, the regions
into its arena. The next report reuses them. So:

> A report is valid only during the callback. Copy what must outlive it.

This is on purpose: building a report allocates nothing, which keeps the agent's cost per
interval flat on the machine it profiles. The copy belongs to the consumer, who knows what it
keeps. Section 8 shows a deep copy into an arena that is reset at every report.

The callback runs on the profiling thread, the same thread that drains the kernel's ring
buffer every 100 ms. While the callback runs, nothing is drained. The kernel keeps counting, so
a callback that is a little slow only makes the next report late (its `duration_ns` says by how
much). But a callback that blocks for long lets the ring fill up, and new stacks are then lost
(`loss.ring_full` counts them). So keep it short: copy, hand over to another thread, return.
Returning an error stops the run.

## 5. Threads and stopping

`profile` blocks, so a server runs it on a thread of its own, one per profiled process:

```
 server thread                         profiling thread
 ─────────────                         ────────────────
 cancel = Cancel.init()
 spawn ───────────────────────────────► profile(gpa, options, &forwarder, on_report)
                                          on_report ──► queue ──► server sends to clients
 client says stop
 cancel.trigger() ───────────────────►    (wakes up, last report)
 thread.join()  ◄─────────────────────── returns .cancelled
 cancel.deinit()
```

`Cancel.trigger()` is safe from any thread, and even from a signal handler (it is one write to
an eventfd). It can be called more than once. Deinit the `Cancel` only after `profile` returned.

## 6. Errors and rights

Errors that come before anything is loaded: `InvalidPid`, `InvalidInterval`, `NoMetrics`,
`MetricNotImplemented`, `ProcessNotFound`. The ones from the kernel: `PermissionDenied`,
`NotSupported` (the kernel is too old), `VerifierRejected` (the kernel refused the BPF
program; the verifier's explanation goes to the log).

The rights it needs:

| right | why |
|---|---|
| `CAP_BPF` | load the program and create its maps |
| `CAP_PERFMON` | open the CPU-clock perf events |
| `CAP_SYS_PTRACE` | read `/proc/<pid>/maps` and the files of a process of another user |
| `CAP_SYSLOG` (optional) | the address of the kernel's `_text`, to place kernel frames |

Root has all of them. The kernel must be Linux 5.15 or newer (`bpf_task_pt_regs`).

## 7. From addresses to names: what the symbolizer will need

The agent sends raw addresses on purpose: symbol tables are big, and turning addresses into
names on the profiled machine would cost it memory and CPU. Everything a symbolizer needs is in
the report.

**A user address.** Find the region that holds it, then the offset in the file:

```
region:  start=0x7f3a12400000  end=0x7f3a12580000  offset=0x28000  path=/usr/lib/libc.so.6
address: 0x7f3a1245c1a3

file offset = address - region.start + region.offset = 0x841a3
```

Then, in that file (found by `region.build_id` in a symbol store, or by `region.path` on the
same machine), turn the file offset into an ELF virtual address with the program headers (the
`PT_LOAD` segment whose file range holds it: `vaddr = offset - p_offset + p_vaddr`), and look
that up in the symbol table (`.symtab`, or `.dynsym` for a stripped library). DWARF line tables
give the file and line, when the binary has them.

Two details matter for correct names:

- **Return addresses.** Every user address after the first is a return address: it points to
  the instruction *after* the call, which can already be the next function. Look up
  `address - 1`. The same for `user[0]` when `leaf_is_return` is true.
- **Special regions.** `[vdso]` has no file: the server can keep a copy per kernel (its symbols
  are `__vdso_clock_gettime` and a few more). An empty `path` is anonymous code, such as a JIT;
  without the JIT's help (perf map files), those addresses stay addresses.

**A Go binary**, even stripped with `-s -w`, keeps `.gopclntab`, the table the agent already
reads to unwind it (Ep15). It also holds every function's name and its file and line tables, so
the symbolizer can name the frames of stripped Go binaries too.

**A kernel address.** `report.kernel.text_address` is where `_text` is at run time. The kernel
moves itself at boot (KASLR), so `address - text_address` is the offset that stays the same, and
the kernel's symbols are found by `report.kernel.build_id` (a `vmlinux` with symbols, or
`/proc/kallsyms` on the same machine).

## 8. The example: feeding a server

From `agent/testing/examples/server_feed.zig`. First, what the server gets: owned plain data,
ready to serialize.

```zig
pub const Message = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    pid: u32,
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    regions: []const agent.Region,
    stacks: []const Stack,

    pub const Stack = struct {
        samples: u64,
        user: []const u64,
        kernel: []const u64,
        complete: bool,
    };
};
```

The callback copies the report into an arena that is reset each time, so the memory stays
bounded, and hands the copy over:

```zig
pub fn on_report(forwarder: *Forwarder, report: *const agent.Report) !void {
    _ = forwarder.arena.reset(.retain_capacity);
    const message = try message_copy(forwarder.arena.allocator(), report);
    try forwarder.send(forwarder.send_context, &message);
    forwarder.messages_sent += 1;
}
```

`message_copy` copies every slice: the regions' paths and build IDs, and each stack's
addresses. And the run on its own thread:

```zig
var cancel = try agent.Cancel.init();
defer cancel.deinit();

var run: Run = undefined;
try run.start(gpa, .{
    .pid = pid,
    .metrics = std.EnumSet(agent.Metric).initOne(.cpu),
    .interval_ms = 1000,
    .duration_s = 0,
    .cancel = &cancel,
}, &forwarder);

// ... later, when the client asks to stop:
cancel.trigger();
const reason = try run.join(); // .cancelled
```

The test at the bottom of that file does exactly this against a busy child process, as root,
and checks that the messages arrive and the run stops on the cancel.

## 9. Shaping it for gRPC

When the gRPC connection comes, `Message` maps to protobuf almost field by field. Two things
are worth doing on the wire that the in-process API does not need:

- **Regions change rarely.** Send them when they change (a library was loaded), not in every
  message: number them, and let the stacks refer to region numbers.
- **Stacks repeat across windows.** A stream can give each distinct stack an id the first time
  it is sent, and then send only `(id, samples)`. That is the same idea the kernel program uses
  between the kernel and the agent (Ep9, Ep11).

A sketch:

```protobuf
message Report {
  uint64 start_unix_ns = 1;
  uint64 duration_ns   = 2;
  uint32 pid           = 3;
  repeated Region regions = 4;   // only when changed
  CpuWindow cpu        = 5;
}
message CpuWindow {
  uint32 sample_hz = 1;
  uint64 samples   = 2;
  repeated Stack stacks = 3;
  map<string, uint64> stops = 4;
  Loss loss        = 5;
}
message Stack {
  uint64 samples = 1;
  repeated uint64 user   = 2;
  repeated uint64 kernel = 3;
  string stop    = 4;
  bool leaf_is_return = 5;
}
```

## 10. What will stay, and what may change

- The numbers that cross the kernel boundary (stop reasons, flags) never change meaning; a new
  stop reason gets a new number.
- New metrics arrive as new optional fields of `Report` (`offcpu`, `mem`, ...), null unless
  asked for. Code that only reads `cpu` keeps working.
- Fields may be added to the structs. Initialize them by name, and code keeps compiling.
- The lifetime rule (valid during the callback only) stays: it is what keeps the agent from
  allocating at every interval.

## 11. Summary

- `profile(gpa, options, &state, on_report)` runs a whole profile and calls back per interval.
- A report is a window of samples, plain data, with every loss and every cut named.
- Copy inside the callback; run `profile` on its own thread; stop it with a `Cancel`.
- Addresses resolve with the regions (user) and the kernel identity (kernel). The symbolizer
  looks up `address - 1` for return addresses.
- `agent/testing/examples/server_feed.zig` is the working example.
