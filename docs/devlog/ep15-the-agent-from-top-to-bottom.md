---
date: 2026-10-31
---

# Ep15: The Agent, From Top to Bottom

Ten episodes built the agent piece by piece. This one puts the pieces together: what each layer
is, why it is built the way it is, and how a sample and a report travel through all of them.
If you read only one episode about the agent, read this one.

The short version:

> The kernel samples and counts, at the sampling rate, without ever stopping the target. The
> agent, at its own pace, keeps the kernel's tables up to date and turns its counts into one
> report per interval. Nothing is lost without being counted, and nothing is guessed without
> being named.

## 1. What the agent must be

The agent runs on production machines, next to the services it watches. That gives it three
goals, in this order (the order TigerStyle uses too):

1. **Safe.** It must never crash or slow down the target, and never show a wrong stack as a
   right one.
2. **Light.** Its cost must be small and flat: no memory that grows with the run, no work that
   grows with the target's load.
3. **Accurate.** Every sample is in the report or in a named loss counter; every cut stack says
   where and why it was cut.

Almost every choice below comes from one of these three.

## 2. The layers

```
                        ┌──────────────────────────────────────────────┐
  the host (CLI,        │ root.zig     the public API: profile, Report │
  server later)  ─────► │ profile.zig  the loop of one run             │
                        │ session.zig  one target, its metrics         │
                        └────────┬───────────────────────┬─────────────┘
                                 │                       │
                        ┌────────▼────────┐     ┌────────▼────────┐
                        │ cpu/            │     │ unwind/         │
                        │ the on-CPU      │────►│ .eh_frame and   │
                        │ metric          │uses │ .gopclntab ->   │
                        │                 │maps │ rows, in maps   │
                        └───┬─────────┬───┘     └───┬────────┬────┘
                            │         │             │        │
                            │    ┌────▼─────────────▼──┐  ┌──▼────────────┐
                            │    │ bpf/                │  │ target/       │
                            │    │ objects, loader,    │  │ maps, regions │
                            │    │ maps, ring buffer   │  │ build IDs,    │
                            │    │ kernel/ programs    │  │ kernel, vDSO  │
                            │    └─────────┬───────────┘  └──┬────────────┘
                            │              │                 │
                        ┌───▼──────────────▼─────────────────▼──┐
                        │ os/  files, timers, poll, perf events,│
                        │      pidfd, cancel, CPUs online       │
                        └───────────────────────────────────────┘
                                        Linux
```

Each layer only uses the ones below it. Read bottom up:

| layer | its job | knows about |
|---|---|---|
| `os/` | thin, checked wrappers around system calls | Linux only |
| `bpf/` | load any BPF object, talk to any map | BPF, not profiling |
| `bpf/kernel/` | the programs that run in the kernel | the wire types only |
| `target/` | what the target is: mappings, files, the kernel, the vDSO | `/proc`, ELF headers |
| `unwind/` | how to walk the target's stacks, as rows in kernel maps | DWARF, Go, BPF maps |
| `cpu/` | the on-CPU metric: sampler, frame cache, windows | everything below |
| `session`, `profile` | one run: the metrics together, and the loop | everything |

And outside the production code: `testing/` holds what only tests need (child processes, Go
builds, end-to-end tests, the API example). Production code never imports it, so the agent
built for production does not contain a byte of it.

## 3. Why these tools

### eBPF, in the kernel

A profiler can sample a process from outside (stop it with `ptrace`, read its stack, let it
go) or from inside the kernel. Stopping a production process 99 times a second per thread is
not light, and not safe. eBPF runs a small, verified program in the kernel at the moment of the
sample, on the CPU that took it, without stopping anything.

The kernel's **verifier** checks every program before it runs: every loop bounded, every memory
access checked. That is why the kernel program looks the way it does: fixed limits everywhere
(`rows_max`, `mappings_max`, search steps), four frames per run, and tail calls to continue.
The verifier turns "the kernel program cannot crash the machine" from a hope into a proof.

### A CPU-clock perf event

The sampling clock is a software perf event, `CPU_CLOCK`, one per CPU, at 99 Hz. Software
rather than the hardware cycle counter, because it exists everywhere (virtual machines often
have no hardware counters) and because its samples measure *time*, which is what an on-CPU
profile reports. 99 and not 100, so it does not tick in lockstep with work that runs on a 10 ms
timer.

### Our own unwinder instead of the kernel's

The kernel can walk a user stack itself (`bpf_get_stackid`), but only by frame pointers, which
most optimized C and Rust code does not keep (Ep9). So the agent compiles each binary's unwind
information into compact **rows**, and the kernel program follows them. The sources:

| binary | source of the rows |
|---|---|
| C, C++, Rust, Zig | `.eh_frame` (DWARF call frame information, kept even in stripped binaries) |
| Go | `.gopclntab` (the runtime's own table, kept even with `-s -w`) |
| the vDSO | the agent's own copy of the vDSO image (Ep13) |
| JIT code, anything else | none: frame pointers, as a fallback |

### Zig everywhere, even in the kernel

The kernel programs are Zig, compiled for the `bpfel` target, and the types the kernel and the
agent share (`bpf/kernel/shared/`) are one Zig file compiled into both. A change on one side is
a compile error on the other, not a silent layout mismatch.

### libbpf, but only for the system calls

The agent has its own ELF reader and loader for BPF objects (Ep8): they are small, and they
check everything. libbpf is used only for the thin `bpf(2)` wrappers and the ring buffer reader,
built from source with libelf and zlib, so the binary is fully static (4.3 MiB in ReleaseSafe,
CLI included) and needs nothing installed on the machine.

### Raw addresses, not names

The agent sends addresses and the regions they belong to, with their build IDs. It does not
read symbol tables or DWARF line tables: those are big, and turning addresses into names costs
memory and CPU that belong to the machine's real work. The server does it (Ep14).

## 4. The kernel's maps: who owns what

| map | type | size | owner | written by | read by |
|---|---|---|---|---|---|
| `cpu_config` | array | 8 B | cpu/sampler | agent | kernel |
| `cpu_state` | per-CPU array | 1560 B per CPU | cpu/sampler | kernel | agent (counters) |
| `cpu_walk_next` | program array | 1 slot | cpu/sampler | agent, once | kernel (tail call) |
| `cpu_counts` | hash | 16384 keys | cpu/sampler | kernel | agent (drains it) |
| `cpu_records` | ring buffer | 512 KiB | cpu/sampler | kernel | agent (every tick) |
| `unwind_rows` | array, 1 value | 3 MiB | unwind/tables | agent | kernel |
| `unwind_modules` | array | 256 × 24 B | unwind/tables | agent | kernel |
| `unwind_procs` | hash | 256 × 16 KiB | unwind/tables | agent | kernel |

Every map has exactly one owner, which creates it and closes it (the double close of Ep12 came
from two owners). The unwind maps are owned by `unwind/tables.zig` and only bound by name into
the CPU program, so the next programs that walk stacks (off-CPU, memory) will share them. In all
about 9 MiB of kernel memory, fixed at start.

## 5. One sample's journey

Every 10 ms on every CPU, the perf event fires and runs `cpu_sample`:

```
 perf event fires on CPU 3
   │
   ▼
 cpu_sample(ctx)
   │  is the running task the target? (cpu_config.tgid)      no ──► return: costs nanoseconds
   │  yes
   ▼
 walk_begin        registers saved when the task entered the kernel (bpf_task_pt_regs);
                   was it inside a syscall? then the pc is a return address
   │
   ▼
 walk_run          up to 4 frames:  pc ──► mapping (unwind_procs, binary search)
   │                                   ──► module (unwind_modules)
   │                                   ──► row (unwind_rows, binary search)
   │                                   ──► CFA, return address, saved rbp
   │                                   (no row? frame pointers, carefully checked)
   │  not finished? tail call into itself (cpu_walk_next), up to 34 runs
   ▼
 walk_finish       kernel stack added if sampled in kernel mode; hash of the whole stack
   │
   ▼
 stack_count       key = {hash, tgid, generation}
   │  key in cpu_counts?   yes ──► atomic +1. Done: the usual case
   │  no
   ▼
 ring_output(record: header + frames) ──► then insert the key with count 1
   (ring full? no key, so a later sample sends it again; counted as ring_full)
```

Three things make this safe and light:

- **The target filter comes first.** A sample of any other process costs a map lookup and a
  comparison.
- **Memory is only read through `bpf_probe_read_user`**, which fails instead of faulting. A
  broken stack costs one sample with a stop reason, never a crash.
- **Repeated stacks cost one lookup and one add.** Frames cross into the agent once per stack per
  window, not once per sample.

## 6. One report's journey

The agent's side runs on one thread, at its own pace, driven by two timers:

```
 every 100 ms (tick):     read the ring buffer into the frame cache

 every interval (report):
   1. generation_advance   cpu_config.generation += 1; the frame cache forgets its oldest epoch;
                           CPUs that came online get an event, CPUs that left lose theirs
   2. regions refresh      read /proc/<pid>/maps; build IDs reused from the last read
   3. tables sync          new binaries get rows (once per binary for the whole run);
                           rows, modules, then the process entry are written, only if changed
   4. counts drain         one lookup_batch, keep older generations, one delete_batch
   5. ring read            frames for every drained count are now in the cache
   6. window build         join counts with frames (no copy), sort, add up the losses
   7. on_report(report)    the host copies what it needs
```

Steps 2 and 3 sit between the generation's advance and its drain on purpose: they give a sample
that read the old generation time to finish (Ep11). Steps 4 and 5 are in that order on purpose
too: the kernel sends a record before its count, so after a drain, the ring holds the frames of
every count drained.

A report allocates nothing: the drained keys, the window's stacks and the frame cache are all
allocated at start, and the window points into the cache instead of copying frames.

## 7. Start and stop

```
 profile()
   check options                 before anything is loaded: a bad option costs nothing
   pidfd_open(pid)               the target's exit becomes a file descriptor to wait on
   session.init
     kernel identity             release, build ID, _text address
     regions                     the first /proc/<pid>/maps read
     tables.init                 the 3 unwind maps, the registry, the vDSO copy
     tables.sync                 rows for every binary the target maps now
     collector.init              the sampler: its maps and program (the verifier runs here),
                                 the frame cache, the ring reader, the buffers
     collector.start             cpu_config.tgid = pid, one perf event per online CPU
   timers armed                  only now, so the first window is a whole one
   loop                          ticks and reports until: duration, target exit, or cancel
   last report                   the partial window
   everything closed             in reverse order, on success and on error
```

## 8. The memory budget

Everything is sized at start, so the agent's memory does not grow with the length of the run
or the load of the target:

| what | where | size | why |
|---|---|---|---|
| unwind rows | kernel | 3 MiB | 2^18 rows of 12 bytes, every binary |
| process entries | kernel | 4 MiB | 256 processes × 512 mappings |
| counts | kernel | 16384 keys | about 2.5 windows of distinct stacks |
| ring buffer | kernel | 512 KiB | about 1300 new stacks per 100 ms tick |
| walk state | kernel | 1.5 KiB per CPU | the walk between runs, and the counters |
| table set rows | agent | 3 MiB | the copy the kernel's row array is written from |
| frame cache | agent | 2 epochs × 4 MiB of frames | untouched pages cost nothing |
| drained counts, window stacks | agent | about 1 MiB | one window's worth |

The one thing that still allocates while running is building the table of a binary the target
maps for the first time: control-plane work, once per binary, freed right after.

## 9. How it stays safe

- **Limits everywhere.** Every loop has a bound, every table a maximum, and each limit has a
  sketch next to it saying why that number.
- **Assertions on our own invariants, errors on outside data.** ELF files, `/proc` and ring
  records are untrusted: checked, refused with an error or a counter. The agent's own state is
  asserted, on both sides of each boundary (for example: every module the process entry names
  is already in the kernel).
- **Two checks across the kernel boundary.** The compiler checks the shared types, and the
  loader checks the maps against what the program declares (`map_check`).
- **Nothing silent.** Lost samples are counted by reason (`Loss`), cut stacks by stop reason
  (`stops`), binaries without tables by cause (`UnwindCoverage`). A wrong stack is never shown
  as a right one: when the agent cannot be sure, it stops the walk and says why.
- **One owner per resource.** Every map, file descriptor and buffer has one owner that creates
  it and releases it.

## 10. Logs

The agent logs through the project's log library, under the scope `agent` (`agent/log.zig`).
It writes only to the logger the host installs, so as a library it is quiet until asked. Lines
come once per run, per binary, per report, or when something changes or fails: never per
sample. Turn on `debug` to see the agent's reasoning, one line per decision. What a short run
looks like (the messages are the real ones; the numbers are an example):

```
INFO  agent: profiling started pid=4242 interval_ms=1000 duration_s=0
DEBUG agent: binary read for unwinding path=/usr/lib/libc.so.6 file_kib=2063 read_kib=61
DEBUG agent: unwind table ready path=/usr/lib/libc.so.6 module=1
INFO  agent: unwind coverage mappings=6 with_table=5 without_table=1 dropped=0
INFO  agent: cpu sampling started pid=4242 sample_hz=99 cpus=8
DEBUG agent: cpu window samples=99 stacks=14 complete_percent=97
INFO  agent: profiling stopped pid=4242 reason=target_exited reports=12 seconds=12
```

## 11. How it is tested

| kind | where | runs |
|---|---|---|
| unit tests | at the bottom of each file | always: `zig build test` |
| kernel tests | the same files, skipped without rights | as root: `sudo ./zig-out/bin/agent-tests` |
| end-to-end | `testing/e2e/`: vDSO, Go, CPU hotplug | as root; hotplug only with `NUSKU_E2E_HOTPLUG=1` |
| the API example | `testing/examples/server_feed.zig` | compiled always, run as root |

The kernel tests check the accounting exactly: every walk is a repeat, a sent record or a drop,
and every counted walk appears in exactly one window. The end-to-end tests run real programs (a
clock reader, a Go program with a frameless function, a child pinned to a CPU taken offline)
and check the stacks the agent produced against what they must be.

## 12. What is next

- **More rows**, so the largest Go binaries fit (Ep16).
- **cgo**: merge a Go binary's `.eh_frame` rows for its C code.
- **The server**: it calls `profile` per target, streams the reports, and symbolizes them
  (Ep14).
- **More metrics**: off-CPU time, memory, locks. Each is a new folder like `cpu/`, sharing the
  unwind tables, and a new field in the report.

## 13. Summary

- Six layers, each using only the ones below: `os`, `bpf`, `target`, `unwind`, `cpu`, then
  `session` and `profile`.
- The kernel samples, walks and counts; the agent keeps the tables and turns counts into
  reports, at its own pace.
- eBPF because it never stops the target, and the verifier proves the kernel side cannot crash.
  Our own unwinder because frame pointers are not enough. Raw addresses because names are the
  server's job.
- Memory fixed at start, every loss counted, every cut named, every resource owned once.
