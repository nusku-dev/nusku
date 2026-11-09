---
date: 2026-11-08
---

# Ep19: Layers, a Pull API, and One Protocol

The profiler worked end to end in Ep18, but the code had become hard to follow. This episode is
a redesign of the agent, and of how the server and the CLI use it. Nothing in the profile
changed; what changed is who knows what:

- The types the agent and the server exchange now live in one place, `shared/protocol`.
- The agent exposes two things, `Run` and `Watch`, each pulled one event at a time.
- Inside, the agent is made of layers. Each layer is one file the others may import, with one
  struct of a few functions. A layer never imports one beside it or above it, and a test
  checks that on every build.

This episode explains each layer: what it is responsible for, why it exists, its public
functions and how to use them, and how the layers work together. Then the agent's API, which
replaces the one in Ep14, and how the server and the CLI use it now.

## 1. What was wrong

Three problems, each of which made the next change harder.

**The API took a lot of thinking to use.** Profiling was one call,
`agent.profile(gpa, options, context, on_report)`, with comptime hooks: a context with
`binary_known`, `binary_begin`, `binary_chunk`, `binary_end` and `binary_abort` took part in
the binary conversation, and one missing hook was a compile error from deep inside. The caller
had to create a `Cancel`, keep it alive longer than the run, copy every report with
`message_from_report` during the callback, and know that the callback ran on the agent's
thread. The root exported more than twenty names: `Report`, `Message`, `cpu.Window`,
`binary.Header`, `kernel_symbols.id`, `processes.watch`, …

**The shared types lived in the agent.** `Region`, `Message`, the binary stream and the
process frames were defined by the agent, so the server imported the agent to know the shape of
a message, and the CLI imported it through the server. Changing the agent's insides could
break the server's types.

**The layers knew each other's insides.** `cpu/` imported `unwind/tables.zig`, which created
BPF maps and read the vDSO image; `symbols/` borrowed that image through the session, and read
ELF files with `unwind/elf_file.zig`; `os/process.zig`, the bottom layer, imported `target/` in
a test. Adding off-CPU sampling would have meant touching all of them.

## 2. The shape now

```
                        ┌──────────────── the agent's API ─────────────────┐
                        │   Run  (init · deinit · next · stop · binary_want)│
                        │   Watch (init · deinit · next · stop)            │
                        └──────────────────────────────────────────────────┘
   parent ────────────  run.zig      watch.zig      message.zig
                         │  │  │         │
             ┌───────────┘  │  └─────────┼──────────────┐
             ▼              ▼            ▼              ▼
   rank 4   ebpf          symbols      processes      (beside each other: never import)
             │  ╲           │  ╲          │
   rank 3    │   unwind     │   │         │
             │  ╱  │        │   │         │
   rank 2   target ◄────────┘   │         │
             │                  │         │
   rank 1   elf ◄───────────────┘         │
             │                            │
   rank 0   os ◄──────────────────────────┘

   shared/protocol: Message, Region, binary, kernel, ProcessFrame, Machine, Metric, RunStop, WatchStop
```

Every layer is a file and a folder of the same name: `target.zig` and `target/`. The file is
the **facade**: the layer's one struct, or for a toolbox its few tools, and the only file of the
layer another layer may import. The folder is the layer's own business.

### The rules

1. A file imports its own layer, the facades of layers **below** it, `log.zig`, and test
   helpers. Nothing else.
2. Layers of the same rank never import each other: `ebpf`, `symbols` and `processes` do not
   know the others exist.
3. Only the parent (`run.zig`, `watch.zig`, `message.zig`) puts layers together.
4. What crosses to the server is a `shared/protocol` type, never an agent type.

### The rules are a test

`agent/testing/layers.zig` reads every source file of the agent, resolves each relative
`@import`, and checks it against the ranks:

```zig
const layers = [_]Layer{
    .{ .name = "os", .rank = 0 },
    .{ .name = "elf", .rank = 1 },
    .{ .name = "target", .rank = 2 },
    .{ .name = "unwind", .rank = 3 },
    .{ .name = "ebpf", .rank = 4 },
    .{ .name = "symbols", .rank = 4 },
    .{ .name = "processes", .rank = 4 },
};
```

An import past a facade, into a layer beside, or into a layer above fails the build and names
the line:

```
layers: unwind/module.zig imports target/process_maps.zig: past another layer's facade
```

That one was real: the first run of the test found it, in a test of `unwind/module.zig`. A new
layer gets a line in this table; nothing else needs to change.

## 3. shared/protocol: what crosses

```
shared/protocol.zig            the facade
shared/protocol/message.zig    Message (Stack, Kernel, clone), Region
shared/protocol/binary.zig     Section, Header, Chunk: a binary sent for its symbols
shared/protocol/kernel.zig     the kernel symbols' identity (build ID + _text) and path
shared/protocol/processes.zig  ProcessInfo, Frame, Machine, MachineCpu
```

| Name | What it is |
|---|---|
| `Message` | One window: when, how long, the pid, the sample rate and counts, the regions, the stacks of raw addresses, and the kernel's identity. `clone` copies it. |
| `Region` | One executable mapping: addresses, file offset, inode, path, build ID. Every address in a message is resolved against these. |
| `binary.Header` / `Chunk` / `Section` | A binary on its way to the server: its build ID, path, segments, section sizes, then chunks of its symbol sections. |
| `kernel` | How the kernel's symbols are named: `[kernel]`, under an ID of build ID plus `_text`. |
| `ProcessInfo`, `ProcessFrame` | One process as `ps` shows it, and every process at one moment. |
| `Machine`, `MachineCpu` | The whole machine in a frame: its CPUs, and its CPU time split into busy, user, system, iowait, irq and steal. |
| `Metric`, `RunStop`, `WatchStop` | What can be measured, and why a run or a watch ended. |

Why here: these are a contract between two programs. The agent fills them and the server reads
them; neither should be able to change them alone. With the server in this process today and
over a network later, the contract stays the same. Moving them also uncovered that `shared/`
had no test step at all: its 13 tests, the server's ELF reader among them, now run with every
build.

## 4. The layers

### 4.1 os: system calls

**Responsible for:** the system calls everything stands on.
**Why:** each is a few lines of `std.os.linux` with the error handling done once, so no layer
above writes a raw system call.
**Imports:** nothing of the agent.

It is a toolbox, not one struct: each tool is small, and each layer takes the few it needs.

| Tool | What it does |
|---|---|
| `process` | `pid_valid`, `current_pid`, `file_open(pid, path)`, `mapping_open(pid, path, start, end)`: open a file as the target sees it, through `/proc/<pid>/map_files` when the path does not open (sandboxes). |
| `timer` | `monotonic_ns`, `realtime_ns`, `boottime_ns`, `deadline_from`, `timeout_ms`, `sleep_ms`, and `Timer`: a timerfd that fires every interval. |
| `poll` | `Poll(Source)`: waits on a set of descriptors named by an enum, and says which are ready. |
| `cancel` | `Cancel`: an eventfd; `trigger` is one write, safe from a signal handler. |
| `pidfd` | `PidFd`: becomes readable when the target exits. |
| `perf_event`, `cpus` | The CPU-clock perf events, and which CPUs are online. |
| `directory`, `anonymous_memory` | Reading directories (for `/proc`), and reserving zeroed memory. |

```zig
const os = @import("../os.zig");
var timer = try os.timer.Timer.init(100);   // fires every 100 ms
```

### 4.2 elf: reading ELF files

**Responsible for:** reading binaries: their headers and the sections asked for, and parsing
`.eh_frame`/`.debug_frame`.
**Why:** both the unwinder and the symbols read ELF files. Before, the symbols borrowed the
unwinder's reader, which tied them together. A file format is neither's business, so it is a
layer below both.
**Imports:** os.

| Tool | What it does |
|---|---|
| `file.load(file, sections, read_max)` | Maps a buffer as long as the file and reads only the headers and the named sections into it, so offsets stay file offsets. Of libc's 2 MiB, about 60 KiB are read. Every offset is checked: the file is untrusted. |
| `file.sections_unwind` | `.eh_frame`, `.gopclntab`, `.debug_frame`. |
| `eh_frame` | `EhFrame`, `Cie`, `Fde`, `Format`: the call-frame records, iterated. |

### 4.3 target: the process profiled

**Responsible for:** what is known about the target: its executable regions with their build
IDs, the kernel it runs on, and the vDSO it shares with the agent.
**Why:** every layer that measures or names something needs the same facts about the target,
read the same way. Having one owner means the vDSO image is read once, and the regions are read
once per window, not once per layer.
**Imports:** os.

```zig
pub const Target = struct {
    pid: u32,
    regions: []const Region,       // as of the last refresh
    kernel: KernelIdentity,        // release, build ID, _text
    vdso: ?VdsoImage,              // the agent's own: every 64-bit process maps the same

    pub fn init(gpa, pid) !Target
    pub fn deinit(target: *Target, gpa) void
    pub fn refresh(target: *Target) !bool
    pub fn vdso_image(target: *const Target) ?*const VdsoImage
};
```

| Function | What it does, and why |
|---|---|
| `init` | Checks the pid, reads the kernel's identity and the vDSO image, and the first regions. `ProcessNotFound` when the target has no regions: gone, or a zombie. Warns once when kernel addresses are hidden (needs `CAP_SYSLOG`). |
| `refresh` | Reads the regions again, into a second arena, reusing the build IDs already known, so a steady target stops allocating. `false` when the target has exited: the last regions are kept, so the last report can still be resolved. |
| `vdso_image` | The image, if any. The `[vdso]` region gets its build ID from it. |
| `deinit` | Frees the arenas and the image. |

The facade also has the few tools on the target's files that the layers above share:
`Region`, `KernelIdentity`, `VdsoImage`, `vdso_path`, `file_open` (a region's file, checked to
be the one mapped: an upgrade may have replaced it), and `build_id_of` with its sizes.

```zig
var target = try Target.init(gpa, pid);
defer target.deinit(gpa);
for (target.regions) |region| std.debug.print("{s}\n", .{region.path});
```

### 4.4 unwind: where each caller is

**Responsible for:** the unwind tables: for every instruction of the target's binaries, how to
find its caller's frame. Built from `.eh_frame`, `.debug_frame` (musl's C) and `.gopclntab`
(Go), once per binary.
**Why its own layer:** the tables are plain computation; only *mirroring* them into the kernel
is BPF. Inside `ebpf/`, every future stack-walking metric (off-CPU, memory, locks) would have
leaned on `cpu/`'s neighbourhood. As a layer below `ebpf`, each metric uses it like it uses
`target`, and its tests run without root.
**Imports:** os, elf, target.

```zig
pub const Unwind = struct {
    pub fn init(unwind: *Unwind, gpa, vdso_image: ?*const VdsoImage) !void
    pub fn deinit(unwind: *Unwind, gpa) void
    pub fn sync(unwind: *Unwind, gpa, pid, regions: []const Region) !void
    pub fn tables(unwind: *const Unwind) Tables
};

pub const Tables = struct {
    rows: []const wire.Row,         // every row: one map value
    modules: []const wire.Module,   // only grows
    entry: *const wire.ProcessEntry,// the target's mappings, each with its module
    coverage: Coverage,             // how much of the code has a table, and why not
};
```

| Function | What it does, and why |
|---|---|
| `init` | Sets up the registry (which binaries have tables). The vDSO image is the source of every target's `[vdso]` table. |
| `sync` | For each region: a binary met before is looked up; a new one is opened (checked by build ID), read with `elf`, and turned into rows. Then the target's entry is rebuilt. Coverage is logged when it changes. |
| `tables` | What has been built, in the exact layout the kernel reads. It does not write anything: the caller decides where the tables go. |

`unwind/wire.zig` is that layout. The unwind layer owns it, and the kernel program gets it from
the build as the named import `unwind_wire`: a BPF module cannot import outside its folder, and
the layout belongs to the tables, not to the program that reads them.

### 4.5 ebpf: the programs in the kernel

**Responsible for:** loading the BPF programs, feeding them the unwind tables, and turning what
they count into windows.
**Why:** everything that needs root and talks to the kernel's BPF is here, behind one struct.
The parent asks for "a window", not for perf events, ring buffers and maps.
**Imports:** os, target, unwind.

```
ebpf/
  bpf/             loading objects, maps, programs, ring buffers (libbpf's system calls)
  kernel/          the programs, written in Zig, compiled for BPF and embedded
  unwind_maps.zig  the three unwind maps, written from Unwind.tables()
  cpu/             the on-CPU metric: sampler, frame cache, windows
  (offcpu/, mem/, … go here, next to cpu/)
```

```zig
pub const Ebpf = struct {
    pub fn init(ebpf: *Ebpf, gpa, target: *const Target, options: Options) !void
    pub fn deinit(ebpf: *Ebpf, gpa) void
    pub fn tick(ebpf: *Ebpf) !void
    pub fn collect(ebpf: *Ebpf, gpa, target: *Target) !Windows
};

pub const Windows = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    unwind: Coverage,
    cpu: ?CpuWindow = null,       // one field per metric; null when not asked for
};
```

| Function | What it does, and why |
|---|---|
| `init` | Refuses no metric or one not built yet (`MetricNotImplemented`) before loading anything. Builds the unwind tables, creates their maps and writes them, loads each metric's program bound to those maps, and starts sampling the target. The first window starts just before sampling, so it is never short. |
| `tick` | Drains the kernel's buffers. Call it at a steady pace (the parent does every ≤100 ms): at 99 Hz on 64 CPUs a tick sees about 634 samples, so the ring cannot fill between two. |
| `collect` | Closes the window: advances the stack generation, refreshes the target's regions (the grace time between the two), rebuilds and rewrites the unwind tables if the regions changed, and collects each metric's window. |
| `deinit` | Stops sampling and unloads everything, in reverse order. |

`UnwindMaps` (inside `ebpf/`) mirrors the tables: `write(pid, tables)` writes the rows, then
the new modules, then the process entry if it changed, so the kernel never follows a reference
to something not there yet. When nothing changed, it writes nothing.

**Adding a metric** is local to this layer: a folder `ebpf/offcpu/` with its program and
collector, a field `offcpu: ?OffcpuCollector` in `Ebpf`, a line in `init`, `tick` and
`collect`, and a field `offcpu: ?OffcpuWindow` in `Windows`. It binds the same unwind maps.
No other layer changes, except `message.zig`, which puts the new window in the message.

### 4.6 symbols: what lets the server name addresses

**Responsible for:** offering each of the target's binaries to the server once per build ID,
and sending the ones it wants: their header and symbol sections, a chunk at a time. Also the
kernel's symbols (from `/proc/kallsyms`, read a piece per step) and names for the vDSO's
functions, which only its jump stubs carry.
**Why:** the agent sends raw addresses; the server names them. It can do that only with the
binaries' symbols, and it should be sent each binary once, only if it does not have it.
**Imports:** os, elf, target. Never ebpf or unwind.

```zig
pub const Symbols = struct {
    pub fn init(symbols: *Symbols, gpa, enabled: bool, pid, vdso_image, kernel) !void
    pub fn deinit(symbols: *Symbols, gpa) void
    pub fn regions_see(symbols: *Symbols, regions: []const Region) void
    pub fn step(symbols: *Symbols) ?Event
    pub fn want(symbols: *Symbols, wanted: bool) void
    pub fn stop(symbols: *Symbols) bool
};

pub const Event = union(enum) {
    offer: Offered,                  // { build_id, path }: answer with want()
    begin: *const binary.Header,
    chunk: binary.Chunk,             // bytes valid until the next step
    end,
    abort,                           // the binary begun will not end
};
```

| Function | What it does, and why |
|---|---|
| `regions_see` | Queues the binaries of a new report not offered yet (at most 256 per run, 16 waiting). |
| `step` | One event, or null when there is nothing to do now. Binaries first, then the kernel's symbols. Bounded: a chunk is 256 KiB, and kallsyms is read 256 KiB per step, so the loop never stalls. |
| `want` | Answers the last `.offer`; no answer is no. During a transfer, `false` drops it (the server's upload failed). |
| `stop` | The run ends. Returns true when a binary had begun, so the caller owes the server an abort. |

It has six functions, not four, because it is a conversation: the server answers each offer,
and the end of a run has to close a transfer cut short. Each function is one step of that.

### 4.7 processes: every process of the machine

**Responsible for:** what `/proc` says about every process: name, user, command, threads, CPU
and memory; and what `/proc/stat` says about the whole machine's CPU.
**Why:** `nusku ps` needs it, and it needs no root and no BPF: only files. It follows the same
shape as the other layers, so it reads the same way.
**Imports:** os.

```zig
pub const Processes = struct {
    pub fn init() Processes
    pub fn deinit(processes: *Processes, gpa) void
    pub fn take(processes: *Processes, gpa) !Frame
};
```

`take` reads `/proc` into one of two tables and measures each process's CPU against the other,
so the first frame has no `cpu_percent`. The frame is valid until the next `take`.

Each look also reads the first line of `/proc/stat`: the time every CPU together spent in each
state since boot. The frame's `machine` is how much of it each state got since the look before,
in `machine.zig`:

```
busy%   = (Δtotal − Δidle − Δiowait) / Δtotal × 100     // 100: every CPU busy
user%   = (Δuser + Δnice) / Δtotal × 100                  // and system, iowait, irq, steal
```

Adding up the processes' `cpu_percent` is not the same number. It misses the processes that
ended between two looks, the first look of a new one, and the time no process owns: interrupts,
and what a hypervisor takes. `/proc/stat` counts all of it. It also says how many CPUs there are,
so the client never has to guess the agent's machine from its own.

## 5. The parent: putting the layers together

```
run.zig      Target + Ebpf + Symbols  →  Run's events
watch.zig    Processes                →  Watch's events
message.zig  Target + ebpf.Windows    →  protocol.Message
```

The parent owns the loop, the timers and the stop, and nothing about how anything is measured.
`Run` keeps its three layers together on the heap, because `Ebpf` and `Symbols` hold pointers
into the `Target` (its vDSO image) and the collectors point into `Ebpf`:

```zig
const Layers = struct {
    target: Target,
    ebpf: Ebpf,
    symbols: Symbols,
};
```

One report, through the layers:

```
 report timer fires
   │
   ├─ ebpf.collect(gpa, &target)
   │     cpu.generation_advance()
   │     target.refresh()              ── regions changed?
   │        └─ unwind.sync(...)  →  unwind_maps.write(unwind.tables())
   │     cpu.collect()            →  Windows
   │
   ├─ symbols.regions_see(target.regions)       new binaries queued
   │
   └─ message.build(arena, { pid, target.regions, target.kernel, &windows })
          →  .report = *const protocol.Message
```

And between reports, every tick (≤100 ms):

```
 tick timer fires
   ├─ ebpf.tick()                 drain the kernel's buffers
   └─ up to 6 × symbols.step()    an offer, a header, chunks (≤ 1.5 MiB per tick), an end
```

`message.build` is the only place that knows both an agent window and the protocol: it
deep-copies into an arena the parent resets each window, because the layers reuse their buffers.

## 6. Using the agent

This replaces the API of Ep14. The whole public API of the agent:

```zig
const agent = @import("agent");

agent.Run, agent.RunOptions, agent.RunEvent
agent.Watch, agent.WatchOptions, agent.WatchEvent
```

### 6.1 Run: profiling one process

```zig
pub const RunOptions = struct {
    pid: u32,
    metrics: std.EnumSet(protocol.Metric) = .initOne(.cpu),
    interval_ms: u32 = 1000,       // between reports
    duration_s: u32 = 0,           // 0: until the target exits or stop()
    binaries: bool = true,         // offer the target's binaries
};

pub const RunEvent = union(enum) {
    report: *const protocol.Message,
    binary_offer: Offered,         // { build_id, path }
    binary_begin: *const protocol.binary.Header,
    binary_chunk: protocol.binary.Chunk,
    binary_end,
    binary_abort,
    stopped: protocol.RunStop,     // the last event; next() is null after it
};
```

| Function | What it does |
|---|---|
| `Run.init(gpa, options)` | Checks the options, then sets everything up: reads the target, builds its unwind tables, loads the programs, starts sampling. About a second for a large target. Needs root, or `CAP_BPF` and `CAP_PERFMON` (and `CAP_SYSLOG` for kernel names). Errors here: `InvalidPid`, `InvalidInterval`, `NoMetrics`, `ProcessNotFound`, `PermissionDenied`. |
| `run.next()` | Waits for and returns the next event. The loop runs inside it: there is no thread of the agent's own. |
| `run.binary_want(wanted)` | Answers a `.binary_offer`, before the next `next()`. Without an answer, the binary is not sent. During a transfer, `false` drops it. |
| `run.stop()` | Ends the run at its next wait. Safe from any thread and from a signal handler. |
| `run.deinit()` | Unloads everything. Call it after `next()` returned null, or to give up early. |

```zig
var run = try agent.Run.init(gpa, .{ .pid = pid, .interval_ms = 1000 });
defer run.deinit();

while (try run.next()) |event| switch (event) {
    .report => |message| store.add(message),               // copy it if you keep it
    .binary_offer => |offered| run.binary_want(!store.has(offered.build_id)),
    .binary_begin => |header| upload.begin(header),
    .binary_chunk => |chunk| upload.chunk(chunk),
    .binary_end => upload.end(),
    .binary_abort => upload.drop(),
    .stopped => |reason| log.info("stopped", .{ .reason = reason }),
};
```

What to know:

- **Every event is valid until the next `next()`.** The message lives in an arena the run
  resets each window; a chunk's bytes are in a buffer the next chunk reuses. Copy what you keep
  (`Message.clone` does it).
- **The end is orderly.** When the run stops (duration, the target's exit, or `stop`), `next`
  gives the last, partial window as a `.report`, then `.binary_abort` if a binary was half sent,
  then `.stopped`, then null. A begun binary always ends in `.binary_end` or `.binary_abort`.
- **The binary conversation is optional.** Ignore `.binary_offer` and nothing is sent; or set
  `binaries = false` and none is offered.
- **Pulling is the backpressure.** The agent does nothing while you handle an event. Handle
  them quickly: the ticks that drain the kernel's buffers happen inside `next`.

### 6.2 Watch: every process, every interval

```zig
pub const WatchOptions = struct {
    interval_ms: u32 = 1000,
    duration_s: u32 = 0,           // 0: until stop()
};

pub const WatchEvent = union(enum) {
    frame: *const protocol.ProcessFrame,   // the first has no cpu_percent
    stopped: protocol.WatchStop,
};
```

```zig
var watch = try agent.Watch.init(gpa, .{ .interval_ms = 1000 });
defer watch.deinit();
while (try watch.next()) |event| switch (event) {
    .frame => |frame| show(frame),
    .stopped => break,
};
```

The first frame comes at once, then one per interval. No root needed.

### 6.3 On a thread of its own

`next` blocks, so a host that has other work puts the run on a thread, and stops it from
another. This is `agent/testing/examples/server_feed.zig`, built and run with every test build
so it cannot go stale:

```zig
fn run_thread(run: *agent.Run, received: *Received) void {
    while (run.next() catch null) |event| switch (event) {
        .report => |message| received.send(message),
        .binary_offer => run.binary_want(false),
        .stopped => |reason| received.stopped = reason,
        else => {},
    };
}

var run = try agent.Run.init(gpa, .{ .pid = child, .interval_ms = 100 });
defer run.deinit();
const thread = try std.Thread.spawn(.{}, run_thread, .{ &run, &received });
// … later, from this thread:
run.stop();
thread.join();
```

### 6.4 Why pull, not callbacks

With callbacks the agent owned the loop and the caller adapted to it: a context type, hooks
checked at compile time, a cancel handle to keep alive. With `next()`, the caller owns the
loop: a `switch` over a union, in plain code, on whatever thread it likes. The compiler checks
that every event is handled, and adding an event later is a compile error in every caller that
forgot it, which is what we want.

## 7. The client: the server and the CLI

The server is the agent's first client. Its run is now a loop over `next()`:

```zig
fn events_take(run: *Run) !protocol.RunStop {
    while (try run.agent_run.next()) |event| switch (event) {
        .report => |message| run.server.ingest(run.target, message) catch |err| switch (err) {
            error.WindowTooLarge => {},       // counted by the store; the run goes on
            else => return err,
        },
        .binary_offer => |offered| {
            run.agent_run.binary_want(!run.server.binary_known(offered.build_id));
        },
        .binary_begin => |header| run.binary_begin(header) catch |err| run.binary_drop(err),
        .binary_chunk => |*chunk| run.binary_chunk(chunk) catch |err| run.binary_drop(err),
        .binary_end => run.binary_end() catch |err| run.binary_drop(err),
        .binary_abort => run.binary_abort(),
        .stopped => |reason| return reason,
    };
    unreachable;
}
```

An upload that fails drops that binary and tells the agent with `binary_want(false)`; the run
goes on. The processes watch is the same loop over `Watch.next()`, three lines long.

What changed for the server's `Controller`:

| Before | Now |
|---|---|
| `start` returned at once; no permission or a gone process came out of `join`. | `start` waits for the agent's setup (about a second) on the calling thread; those errors come out of `start`. A stop can never come before the run exists. |
| The controller created a `Cancel` per run, and `cancel_of` / `watch_procs_cancel_of` handed it out. | `interrupt()` stops every run and the watch. It only writes to eventfds, so it is safe from a signal handler. |
| A scratch buffer per run, to copy each report. | None: the message comes already built. |

The CLI's Ctrl-C handler is now one line, `controller.interrupt()`. Writing this fixed a race:
the CLI released its handler after `join`, which frees what the handler would trigger; it now
releases it before.

### Room for gRPC

Today the only client is in-process: `server/control/run.zig` pulls the events and calls the
server. The agent's whole output is `Run.next()`, and every event is a `shared/protocol` type.
A gRPC connection, later, is a second consumer of the same loop, in an agent process: it sends
each event over the network. On the server, the receiver calls the same `ingest`,
`binary_known` and `upload_*` that the in-process run calls. The agent does not change, and
neither do the server's store and symbolizer. On the CLI side, `src/clients/local.zig` is the
one client today; a `clients/remote.zig` would sit next to it.

## 8. How it was done

In three steps, each green before the next:

1. **The protocol.** The shared types moved to `shared/protocol`; the agent's copies became
   aliases, and the server and CLI switched to the protocol's names.
2. **The API.** `Run` and `Watch` replaced `profile` and `processes.watch`. The offer and the
   transfer went from calling hooks to returning one event per `step`. The server's run and
   watch became loops over `next()`, and the root shrank to six exports.
3. **The layers.** Files moved by a script that also rewrote every relative import; then each
   facade was written, `session.zig` split into `Target` and `Ebpf`, `unwind/tables.zig` split
   into `Unwind` and `UnwindMaps`, and the layer test went in.

The tests went from 220 to 231 without root, all passing. Some are new (`Run`, `Watch`,
`Target`, the layer rule); others existed but never ran, because the files that held them were
reachable from no test block. Each facade now lists its folder's files in its own test block, so
a new file is tested as soon as its layer imports it.

## 9. Summary

- **One protocol.** What the agent and the server exchange is `shared/protocol`, owned by
  neither.
- **Two things to use.** `Run` and `Watch`: `init`, `next` until null, `stop` from anywhere,
  `deinit`. Every event is valid until the next `next`.
- **Seven layers, one facade each.** `os` and `elf` are toolboxes; `Target`, `Unwind`, `Ebpf`,
  `Symbols` and `Processes` are one struct of a few functions each. A layer imports only the
  ones below it, never one beside it, and a test enforces it.
- **The parent puts them together.** `run.zig` turns target, ebpf and symbols into events;
  `message.zig` turns a window into a message.
- **Room to grow.** A metric is a folder under `ebpf/`; another kind of symbols is a file under
  `symbols/`; a network transport is another consumer of `next()`.
