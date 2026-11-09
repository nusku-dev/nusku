---
date: 2026-11-09
---

# Ep22: The Agent, a Reference

Ep19 told how the agent was redesigned. Since then, a few things have moved: every layer is now a
folder with its facade inside, `ebpf` became `metrics`, and the watch reports the whole
machine's CPU. This episode is not a story. It is the agent as it is today, to come back to when
something has to be added or changed.

1. [What the agent is, and how to use it](#1-what-the-agent-is-and-how-to-use-it)
2. [The files](#2-the-files)
3. [The layers and who imports whom](#3-the-layers-and-who-imports-whom)
4. [Each layer](#4-each-layer)
5. [The parent: run, watch, message](#5-the-parent-run-watch-message)
6. [A run from start to end](#6-a-run-from-start-to-end)
7. [Extending the agent](#7-extending-the-agent)
8. [Tests](#8-tests)

## 1. What the agent is, and how to use it

The agent does two things, and exports one struct for each:

| | What it does | Needs |
|---|---|---|
| `Run` | Profiles one process: a report of its stacks every interval, and its binaries so the server can name the addresses. | root, or CAP_BPF + CAP_PERFMON (CAP_SYSLOG for kernel names) |
| `Watch` | Every process of the machine, and the machine's CPU, a frame every interval. | nothing: `/proc` only |

Both are **pulled**: you call `next()` and get one event, until it returns null. Nothing calls
you back, and nothing runs behind your back: the agent's work happens inside `next()`. So the
caller decides the thread, the pace, and where the events go (a server in this process today,
a network connection later).

```zig
const agent = @import("agent");

var run = try agent.Run.init(gpa, .{ .pid = pid, .interval_ms = 1000, .duration_s = 10 });
defer run.deinit();
while (try run.next()) |event| switch (event) {
    .report => |message| send(message),               // *const protocol.Message
    .binary_offer => |offer| run.binary_want(have(offer.build_id) == false),
    .binary_begin, .binary_chunk, .binary_end, .binary_abort => forward(event),
    .stopped => |reason| log(reason),                 // duration, target_exited, cancelled
};
```

```zig
var watch = try agent.Watch.init(gpa, .{ .interval_ms = 1000 });
defer watch.deinit();
while (try watch.next()) |event| switch (event) {
    .frame => |frame| show(frame),                    // *const protocol.ProcessFrame
    .stopped => |reason| log(reason),                 // duration, cancelled
};
```

| Function | Run | Watch |
|---|---|---|
| `init(gpa, options)` | Reads the target, builds its unwind tables, loads the BPF program and starts sampling. Can take a second. | Takes the first look at `/proc`, then arms the timer. |
| `deinit()` | Unloads everything. | Frees everything. |
| `next()` | The next event, waiting for it. Null after `.stopped`. | The same. |
| `stop()` | Ends at the next wait. Safe from any thread and from a signal handler. | The same. |
| `binary_want(bool)` | Answers a `.binary_offer`. Not answered means no. During a transfer, `false` drops it. | |

**Options.** `Run`: `pid`, `metrics` (`.cpu` today), `interval_ms` (1000), `duration_s` (0: until
the target exits or `stop`), `binaries` (true). `Watch`: `interval_ms` (1000), `duration_s` (0).

**Events are borrowed.** A `.report`, a `.frame` or a chunk points into the agent's memory, and
is valid until the next `next()`. Copy what you keep. The server's `Feed.take` does.

**Everything an event carries is a `shared/protocol` type**: `Message`, `Region`,
`binary.Offer/Header/Chunk`, `ProcessFrame`, `Machine`, `RunStop`, `WatchStop`. Nothing of the
agent's own crosses. That is what lets a transport be added without touching the agent.

## 2. The files

```
agent/
  root.zig        the module: Run, Watch, their options and events. Nothing else is public.
  run.zig         the parent of a run: target + metrics + symbols → RunEvent
  watch.zig       the parent of a watch: processes → WatchEvent
  message.zig     a protocol.Message, built from the target and a window
  log.zig         the agent's log scope
  build.zig       the module, the BPF programs compiled and embedded

  os/         os.zig         toolbox: process, timer, poll, cancel, pidfd, perf_event, cpus,
                             directory, anonymous_memory
  elf/        elf.zig        toolbox: file (elf_file.zig), eh_frame
  target/     target.zig     Target; regions, process_maps, build_id, mapped_file, kernel, vdso
  unwind/     unwind.zig     Unwind; registry, module, cfi, cfi_machine, go_pclntab, table,
                             table_set, process_table, wire
  metrics/    metrics.zig    Metrics; unwind_maps.zig
              bpf/           loader, object, program, map, ring_buffer, libbpf
              kernel/        cpu.bpf.zig, helpers.zig, shared/cpu_wire.zig (compiled for BPF)
              cpu/           collector, sampler, frame_cache, window
  symbols/    symbols.zig    Symbols; binary, transfer, vdso_symbols, kernel_symbols
  processes/  processes.zig  Processes; proc, machine, stat, statm, status, cmdline, users

  testing/        test-only code: process.zig, go_build.zig, e2e/, examples/
```

**The root holds only the parent.** Every layer, `os` too, is a folder, and its facade is the
file named like it: `metrics/metrics.zig`. A file anywhere else in the folder belongs to the layer
and is nobody else's business.

## 3. The layers and who imports whom

```
   root.zig ─────────────── exports Run and Watch only
                 │
   parent ──── run.zig ──────────────────── watch.zig      message.zig
                 │       │         │            │              │
   rank 4      metrics  symbols   (beside)    processes     (target, metrics)
                 │  ╲      │  ╲                 │
   rank 3        │   unwind │   │               │
                 │  ╱  │    │   │               │
   rank 2      target ◄─────┘   │               │
                 │              │               │
   rank 1      elf ◄────────────┘               │
                 │                              │
   rank 0      os ◄─────────────────────────────┘
```

| Layer | Rank | Imports | Is |
|---|---|---|---|
| `os` | 0 | nothing of the agent | toolbox |
| `elf` | 1 | os | toolbox |
| `target` | 2 | os | `Target` |
| `unwind` | 3 | os, elf, target | `Unwind` |
| `metrics` | 4 | os, target, unwind | `Metrics` |
| `symbols` | 4 | os, elf, target | `Symbols` |
| `processes` | 4 | os | `Processes` |

The rules (Ep21 §2 has them in full):

- A file imports its own layer, the **facades** of layers **below** it, `log.zig`, named modules
  (`std`, `shared`), and `testing/`. Nothing else.
- Layers of the same rank never import each other. `metrics`, `symbols` and `processes` do not
  know the others exist; `run.zig` puts them together.
- An import path shows what it crosses. From `metrics/`, `../target/target.zig` is a facade
  below: fine. `../target/regions.zig` goes past a facade, and `../symbols/symbols.zig` reaches
  beside: both are wrong. There is no test for this; it is kept by reading the imports.

## 4. Each layer

### os: the system calls

**Why:** every layer needs a few system calls, and none should write its own. Small tools, so a
toolbox: `os.zig` names them, each layer takes what it needs.

| Tool | What it is for |
|---|---|
| `process` | pids: valid, current, reading `/proc/<pid>/…` |
| `timer` | clocks (monotonic, realtime, boottime) and a timerfd `Timer` (`init`, `period_set`, `expirations_read`), deadlines |
| `poll` | `Poll(Source)`: wait on several fds, get back which are ready, by name |
| `cancel` | an eventfd to wake a poll from another thread or a signal handler |
| `pidfd` | know when the target exits, without polling `/proc` |
| `perf_event` | open a sampling perf event on one CPU |
| `cpus` | the CPUs online, and the possible ones |
| `directory` | read a directory's entries (from `shared`) |
| `anonymous_memory` | mmap'd memory, for buffers too big for the stack |

### elf: reading ELF files

**Why:** both the unwinder and the symbols read ELF files, and neither should own that.

| Tool | What it is for |
|---|---|
| `file` | open an ELF file, read its headers and only the sections asked for |
| `eh_frame` | parse `.eh_frame` and `.debug_frame` into CIEs and FDEs |

### target: the process profiled

**Why:** every layer of a run needs to know the target the same way: where its code is mapped,
from which file, with which build ID, on which kernel. Read once, in one place.

```zig
pub const Target = struct {
    pid: u32,
    regions: []const Region,   // the executable mappings, as of the last refresh
    kernel: KernelIdentity,    // release, build ID, _text address
    pub fn init(gpa, pid) !Target            // ProcessNotFound if gone or a zombie
    pub fn deinit(target, gpa) void
    pub fn refresh(target) !bool             // reads the maps again; true if they changed
    pub fn vdso_image(target) ?*const VdsoImage
};
```

Also the tools both `unwind` and `symbols` need on a region's file: `file_open` (opens the file
and checks it is the one mapped), `build_id_of`, `vdso_path`. The regions keep the last read when
the target exits, so the last report can still use them.

### unwind: where each frame's caller is

**Why:** without frame pointers, a stack can only be walked with tables that say, for every
instruction, where the return address and the caller's frame are. Building them is big work and
has nothing to do with BPF, so it is its own layer below `metrics`.

```zig
pub const Unwind = struct {
    pub fn init(unwind: *Unwind, gpa, vdso_image) !void
    pub fn deinit(unwind, gpa) void
    pub fn sync(unwind, gpa, pid, regions) !void   // a table per new binary; the process entry
    pub fn tables(unwind) Tables                   // rows, modules, entry, coverage
};
```

Tables come from `.eh_frame` / `.debug_frame` (CFI, run through `cfi_machine`) or from Go's
`.gopclntab`. A binary is built once per build ID (the registry) and its rows go into one shared
array. `wire.zig` is the layout the kernel reads; the BPF program imports the same file (as
`unwind_wire`, from `build.zig`), so the two cannot disagree. `Coverage` says how much of the
target has tables, and why the rest has none.

### metrics: what is measured

**Why:** this is what the agent is for: measure the target, a window at a time. How (BPF
programs, perf events, ring buffers, maps) stays inside. It also keeps the unwind tables in the
kernel, because its programs walk stacks with them: that is why it imports `unwind`.

```zig
pub const Metrics = struct {
    pub fn init(metrics: *Metrics, gpa, target: *const Target, options) !void
    pub fn deinit(metrics, gpa) void
    pub fn tick(metrics, gpa, target: *Target) !void       // drain the kernel's buffers
    pub fn collect(metrics, gpa, target: *Target) !Windows // close the window
};

pub const Windows = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    unwind: Coverage,
    cpu: ?CpuWindow = null,   // one field per metric; null when not asked for
};
```

| Function | What it does |
|---|---|
| `init` | Refuses no metric, or one not built yet (`MetricNotImplemented`), before loading anything. Builds the unwind tables, writes them into their maps, loads each metric's program bound to those maps, starts sampling. Must stay at its address: the collectors point into it. |
| `tick` | Drains the buffers. Call it at a steady pace (`run.zig` does every ≤100 ms, every 25 ms in the first second). When walks stop at code with no table (a library just mapped), it refreshes the target and its tables at once, at most every 500 ms. |
| `collect` | Ends the window: advances the stack generation, refreshes the regions and tables, returns each metric's window. The next window starts now. |

Inside: `bpf/` loads objects and talks to maps (our own loader; from libbpf only the thin
`bpf(2)` wrappers and the ring buffer reader); `kernel/` holds the
programs, written in Zig and compiled for BPF by `build.zig`; `unwind_maps.zig` writes the
tables into three maps in an order the kernel can always follow; `cpu/` is the on-CPU metric:
the `collector` (`init`, `start`, `tick`, `generation_advance`, `collect`), its `sampler`, its
frame cache, its window.

### symbols: the binaries, sent so the server can name addresses

**Why:** the agent sends raw addresses; the server names them. It can only do that with the
binaries' symbol tables, and the agent is the one that can read the files. Offered once per
build ID, so a server that already has one says no.

```zig
pub const Symbols = struct {
    pub fn init(symbols: *Symbols, gpa, enabled, pid, vdso_image, kernel) !void
    pub fn deinit(symbols, gpa) void
    pub fn regions_see(symbols, regions) void   // queue the binaries not seen yet
    pub fn step(symbols) ?Event                 // one event: offer, begin, chunk, end, abort
    pub fn want(symbols, wanted: bool) void     // the answer to an offer
    pub fn stop(symbols) void                   // no more offers; a transfer begun finishes
};
```

It is a conversation, which is why it has more than four functions: offer → `want` → begin →
chunks → end. The kernel's symbols come first: `/proc/kallsyms` is read on a thread of its own as
soon as the server wants them, so a short run still names kernel frames. A binary is sent as its
header and only the sections that name things, in chunks of 256 KiB. The vDSO has no file, so it
is sent from the agent's own image, with names for its jump stubs.

### processes: every process of the machine

**Why:** `nusku ps` needs it, and it needs no BPF and no root: files only. It is a layer like the
others so it reads the same way.

```zig
pub const Processes = struct {
    pub fn init() Processes
    pub fn deinit(processes, gpa) void
    pub fn take(processes, gpa) !Frame     // every process now, and the machine
};
```

Each `take` reads `/proc` into one of two tables and measures against the other. So the first
frame has no CPU, neither for a process nor for the machine. A process's `cpu_percent` is a
share of one CPU, measured between its own two reads. The frame's `machine` comes from
`/proc/stat` (`machine.zig`): the CPUs online and how all of them together spent their time
(busy, user, system, iowait, irq, steal). That total includes what no process shows: processes
that ended between looks, interrupts, steal.

## 5. The parent: run, watch, message

The parent is the only code that knows more than one layer. It owns the order of things.

**`run.zig`** keeps `Target`, `Metrics` and `Symbols` together on the heap, because `Metrics`
and `Symbols` point into the `Target` (its vDSO image). One `poll` waits on four things:

| Source | What happens |
|---|---|
| tick timer (25 ms for the first second, then ≤100 ms) | `metrics.tick`, then up to 6 binary steps (`symbols.step`) are given out by the next `next()` calls |
| report timer (`interval_ms`) | `metrics.collect` → `message.build` → `.report` |
| the target's pidfd | a last report, then the end: `target_exited` |
| cancel (`stop`) or the deadline | a last report, then the end: `cancelled` / `duration` |

At the end, `symbols.stop()` is called and a transfer already begun runs to its end. Then comes
`.stopped`.

**`watch.zig`** is the same shape, smaller: `Processes` and one timer. The first frame is taken
in `init`, so the first interval is a whole one.

**`message.zig`** makes the one thing the server receives, a `protocol.Message`, from the
target's regions and kernel and a window of `Metrics`. Everything is deep-copied into the run's
arena, because the layers reuse their buffers for the next window.

## 6. A run from start to end

```
Run.init
  target   = Target.init(pid)                 read /proc/<pid>/maps, build IDs, the kernel
  metrics  .init(target)                      unwind.sync → unwind_maps.write → load cpu.bpf
                                              → a perf event per CPU → sampling starts
  symbols  .init(...); regions_see(regions)   the binaries queued; the kernel first
  timers armed: the first window starts now

next() … next() …
  tick     metrics.tick                       drain the ring; unknown code → refresh tables
           symbols.step × ≤6                  → .binary_offer / _begin / _chunk / _end
  report   metrics.collect → message.build    → .report
           symbols.regions_see(regions)       new libraries are offered too

target exits / stop / duration
  report   the last window                    → .report
  close    symbols.stop; finish the transfer  → .binary_chunk … .binary_end
           → .stopped(reason)                 then null
```

## 7. Extending the agent

Each change below lands in one layer, plus the parent and the protocol when something new
crosses to the server. If a change seems to need a layer to import one beside it, the shared
part belongs in a layer below both.

### A new metric (off-CPU, memory, …)

All inside `metrics/`; nothing below it changes.

1. `metrics/kernel/offcpu.bpf.zig`: the program, added in `agent/build.zig` with
   `add_kernel_program`, which also gives it `unwind/wire.zig` as the `unwind_wire` import. If
   it walks stacks, its collector binds the unwind maps (`UnwindMaps.bindings()`).
2. `metrics/offcpu/`: its collector, shaped like `cpu/collector.zig`: `init`, `deinit`,
   `start`, `tick`, `collect`.
3. `metrics/metrics.zig`: a field `offcpu: ?OffcpuCollector`, one line in `init`, `deinit`,
   `tick` and `collect`, a field `offcpu: ?OffcpuWindow` in `Windows`, and `.offcpu` out of the
   `MetricNotImplemented` list.
4. `shared/protocol/`: what a message carries for it.
5. `message.zig`: the window into the message.

`Run` already takes `metrics: EnumSet(Metric)`, so the caller asks for it with no new API.

### More about each process in the watch

1. A reader in `processes/` (like `statm.zig`: one file, `read(pid)`, a pure `parse`).
2. Read it in `proc.zig`, and put the field in `ProcessInfo` in `shared/protocol/processes.zig`.
3. If it is a rate (like CPU), measure it in `processes.zig` against the look before.

Something about the whole machine goes in `machine.zig` and `Machine`, the same way.

### Another kind of symbols (a JIT's map, debuginfo, …)

A file in `symbols/`, and a new kind of transfer, or new sections in `binary.zig`. `run.zig` and
the events do not change: the server sees an offer, then chunks.

### Unwinding a new kind of binary

A source next to `go_pclntab.zig` in `unwind/`, and a branch in `module.zig` that picks it. The
rows it makes are the same `wire.Row`, so neither the kernel program nor `metrics` changes.

### A new system call

A file in `os/`, named in `os/os.zig`. Only `os` talks to the system directly.

### A new layer

1. A folder `name/` with `name/name.zig`: the struct, `init`, `deinit`, and one to four
   functions, with a header saying what it is responsible for and what it stands on.
2. Its rank: one above the highest layer it imports. It imports nothing beside it.
3. Its line in `root.zig`'s layer list and test block.
4. Name it for what it gives, not how it works.

### A new transport (gRPC, …)

Nothing in the agent changes. A transport is a loop around `next()` on the agent's side that
sends each event, and one around `Feed.take()` on the server's side that answers. Every event is
already a `shared/protocol` type.

## 8. Tests

| Where | What |
|---|---|
| in each file, after `// ---- tests` | the unit tests of that file; pure functions (`parse`, `cpu_percent`) tested without a process |
| `agent/testing/process.zig`, `go_build.zig` | helpers: a child that burns CPU, reaping, building the Go test program |
| `agent/testing/e2e/` | a layer or two against real processes: Go and vDSO unwinding, CPU hotplug, the watch against known children |
| `agent/testing/examples/server_feed.zig` | the public API as a server uses it, so the example cannot go stale |
| `testing/` (repo root) | `make check`: the whole `nusku` binary against C, Go, Zig and threaded apps with known profiles |

Code used only by tests lives under `testing/`, never in the agent's files. A test that needs
root says so in its name and skips without it. `zig build test` runs them all; `sudo
zig-out/bin/agent-tests` runs the root ones too; `make check SUDO="sudo -A"` in `testing/` checks
the profiles.
