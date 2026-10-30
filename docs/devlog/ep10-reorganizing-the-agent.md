---
date: 2026-10-31
---

# Ep10: Reorganizing the Agent

After Ep9 the on-CPU profiler worked, but the agent's code had grown in whatever direction the
last feature pushed it. Today is a cleanup episode, but not a cosmetic one: the new layout is
what lets the next metrics (off-CPU, memory, locks) and the gRPC connection fit in without
another rewrite.

The short version:

> One folder per layer. Each layer only talks to the one below it. Every number the kernel and
> the agent share is written down once.

## 1. What was wrong

The agent had grown three folders that overlapped: `clibs/`, `ebpf/` and `sessions/`. Some
examples of what that looked like:

- Two files called `oncpu.zig`: `ebpf/metrics/oncpu/oncpu.zig` (the BPF program and its maps)
  and `sessions/oncpu/oncpu.zig` (perf events and the windows). Inside them, `OnCpu` and
  `OncpuSession`, `TableMaps` and `UnwindMaps`. Hard to say which is which without opening both.
- `maps_window.zig` held a type called `Region`. `unwind_entry.zig` held the code that writes
  the unwind tables into the kernel.
- The kernel program and the agent both declared the unwind table layout (`Row`, `Module`,
  `Mapping`, `ProcessEntry`) and the stop reasons, each with its own copy, and a comment asking
  to "keep the numeric values consistent with compactwalk.zig", a file that no longer existed.
- Two build modules (`ebpf` and `agent`) for what is really one library.

None of this was a bug by itself. But duplicated numbers are how bugs are born: change one copy,
forget the other, and the kernel reads the agent's data with the wrong layout.

## 2. The new layout

```
agent/
  root.zig        the public API: profile, Report, Metric, Region, cpu.Window
  profile.zig     the main loop of one run
  session.zig     one target, the metrics asked for, and what they share

  os/             system calls: file, timer, poll, pidfd, perf_event, cancel
  bpf/            BPF plumbing: object (ELF), loader, map, program, ring_buffer
    kernel/       the BPF programs themselves (compiled for the bpfel target)
      shared/     cpu_wire.zig, unwind_wire.zig: what both sides agree on
  target/         what we know about the target: process_maps, regions, build_id, kernel
  unwind/         .eh_frame -> rows, the registry of binaries, tables.zig (writes the maps)
  cpu/            the on-CPU metric: sampler, frame_cache, window, collector
```

Read it bottom up, and every layer only uses the layers under it:

```
            profile.zig
                 │
            session.zig
           ┌─────┴──────┐
         cpu/        unwind/
           │    ┌──────┘ │
           │    │     target/
           └─ bpf/ ──────┘
                 │
                os/
```

`os/` knows nothing about BPF. `bpf/` knows nothing about CPU profiling: it can load any
program from any object. `cpu/` is the only place that knows what an on-CPU sample is.

## 3. One file the kernel and the agent both compile

The most important new files are the two in `bpf/kernel/shared/`.

`unwind_wire.zig` holds the unwind table layout: `Row`, `Module`, `Mapping`, `ProcessEntry`,
the CFA types, and every limit (`rows_max`, `mappings_max`, the search step counts).

`cpu_wire.zig` holds the CPU protocol: `Config`, `CountKey`, `RecordHeader`, `WalkState`, the
`StopReason` enum, and the sizes of the counts map and the ring.

Both files are compiled **twice**: into the kernel program (target `bpfel`, freestanding, no
operating system) and into the agent. That is why they have two rules:

1. Only `extern struct`s and constants: the layout must be the same on both sides, byte for byte.
2. No `@import("std")`: the BPF target has no OS to build std against.

They also check themselves at compile time. For example:

```zig
// The bounded searches must converge before they run out of steps.
if ((1 << row_search_steps_max) <= rows_max) @compileError("too few row search steps");
```

If someone raises `rows_max` and forgets the step count, the build fails. Without this, the
kernel's binary search would silently stop one step early and return the wrong row for some
addresses, which is the kind of bug that takes a week to find.

There is one more check, at run time this time. The unwind maps are created by the agent
(`unwind/tables.zig`), not from the BPF object, because several programs will share them. So
before loading the CPU program, the loader compares each shared map with what the program
declares:

```zig
pub fn map_check(object: *const Object, name: []const u8, map: *const Map) Error!void {
    const definition = try object.map_definition(name);
    if (definition.map_type != map.spec.map_type) return error.MapMismatch;
    if (definition.key_size != map.spec.key_size) return error.MapMismatch;
    ...
}
```

Two sides, two checks: the compiler checks the types, and the loader checks the maps.

## 4. Why this layout scales

Two things are coming: more metrics, and gRPC.

**More metrics.** Off-CPU and memory profiling also need user stacks, so they need the same
unwind tables. `unwind/tables.zig` owns the three unwind maps, and any program binds them by
name:

```
           unwind/tables.zig  (creates and writes the maps, once)
             │       │       │
     unwind_rows  unwind_modules  unwind_procs
             │       │       │
     ┌───────┴───────┴───────┴────────┐
  cpu.bpf.zig                    offcpu.bpf.zig (later)
```

The tables are built once, however many programs read them. A new metric is a new folder like
`cpu/` with the same shape (init, start, tick, collect, deinit), and one new field in the
report:

```zig
pub const Report = struct {
    start_unix_ns: u64,
    duration_ns: u64,
    pid: u32,
    regions: []const Region,
    kernel: kernel.Identity,
    unwind: tables.Coverage,
    cpu: ?cpu.Window = null,
    // offcpu: ?offcpu.Window = null,   <- the next metric goes here
};
```

**gRPC.** The report is plain data: numbers, enums and slices of addresses. No pointers to
kernel objects, no symbol names (the server resolves those from the addresses and the regions'
build IDs). So it can be turned into a protobuf message field by field, without changing the
agent.

## 5. TigerStyle

The rewrite follows [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
The parts that changed the code the most:

- **snake_case for functions**, with the noun first: `cpu_clock_open`, `counts_drain`,
  `epoch_advance`, `row_find`. Related names line up: `modules_write`, `process_write`.
- **Units and qualifiers last**: `interval_ms`, `duration_ns`, `rows_max`, `generation_current`.
- **No line over 100 columns, no function over 70 lines.** The longest function was the DWARF
  instruction interpreter (90 lines). It is now split by what an instruction changes: the
  location, the CFA rule, or one register's rule. The loop and the big switch stay in the parent.
- **Allocate at init.** The CPU collector allocates every buffer when it starts: the drained
  counts, the window's stacks, the frame cache. A report allocates nothing.
- **Assert the positive and the negative space.** Assertions guard the agent's own invariants:
  "every module the process entry names is already in the kernel", "the kernel's counters only
  grow". Data from outside (ELF files, `/proc`, ring records) is never asserted on: it is
  checked and refused with an error or a counter, because a bad file is an operating error, not
  a bug.
- **Say why.** Every limit has a back-of-the-envelope sketch next to it. For example the ring
  buffer: "a new stack's record is about 400 bytes; the agent drains the ring every 100 ms, so
  512 KiB holds about 1300 new stacks per drain".

## 6. Summary

- Five layers: `os/`, `bpf/`, `target/`, `unwind/`, `cpu/`, then `session` and `profile`.
- What the kernel and the agent share is written once, in `bpf/kernel/shared/`, and checked by
  the compiler on one side of the boundary and by the loader on the other.
- The unwind tables have one owner and can be shared by future programs.
- The report is plain data, ready for the wire.

The next episode is about the biggest change hiding inside this reorganization: the counts map
no longer grows forever.
