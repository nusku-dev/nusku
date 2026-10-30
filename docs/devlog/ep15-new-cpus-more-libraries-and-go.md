---
date: 2026-10-31
---

# Ep15: New CPUs, More Libraries, and Go

Three accuracy steps for the on-CPU profiler, smaller than the last ones but each closing a
real gap:

1. a CPU that comes online during a run was never sampled;
2. a process with more than 128 libraries lost the frames of the rest;
3. Go programs were walked by frame pointers only, which silently skips frames.

## 1. CPUs that come online later

The agent opens one perf event per CPU: each event fires 99 times a second on its CPU and runs
the BPF program there. It opened them once, at start, for the CPUs online then.

But CPUs come and go: hotplug, a cloud VM resized, CPUs parked to save power. A CPU that came
online after the start had no event, so the target's work there was never sampled. The profile
would show less CPU time than the target used, and nothing would say so.

Now the events live in one slot per **possible** CPU (the kernel says how many CPUs can ever
exist), and every report reads the online list again:

```
/sys/devices/system/cpu/online   "0-3,5,7"

slot:    0    1    2    3    4    5    6    7
online:  yes  yes  yes  yes  no   yes  no   yes
event:   ●    ●    ●    ●    ·    ●    ·    ●     ● open   · none
```

A CPU online without an event gets one; a CPU offline with an event has it closed. It is one
small file read per report, on the control plane, not per sample.

The test takes the last CPU offline, starts sampling a busy child, brings the CPU back, pins the
child to it, and reports. Every sample of a pinned child is taken on that one CPU:

```
hotplug e2e: cpu 7 back online, 300 samples of the pinned child
```

300 samples at 999 Hz in 300 ms: all of them on the CPU that came back. The test changes the
machine for a moment, so it only runs with `NUSKU_E2E_HOTPLUG=1`.

One case is left, and written down in the code: a CPU that goes offline and comes back between
two reports keeps its old event, and the agent does not rely on the kernel keeping an event
alive across that.

## 2. More libraries per process

The kernel program finds a pc's mapping with a binary search over the process's executable
mappings. Their number was fixed at 128, because the search must have a fixed number of steps
for the verifier. Most libraries map their code once, so 128 mappings is about 128 libraries.
A JVM maps about a hundred; a browser, two or three hundred. Past 128, frames in the libraries
that did not fit could not be unwound (the report counts them in `mappings_dropped`).

The limit is now 512, with 10 search steps. The catch is memory: the process map is
preallocated, and an entry grows from 4 KiB to 16 KiB. So the map now holds 256 processes instead
of 1024:

| | before | now |
|---|---|---|
| mappings per process | 128 | 512 |
| search steps | 8 | 10 |
| entry size | 4 KiB | 16 KiB |
| processes | 1024 | 256 |
| kernel memory | 4 MiB | 4 MiB |

The agent profiles one process today, so 256 leaves room for the multi-target agent later. The
compile-time checks of Ep10 hold the search steps and the limit together.

## 3. Go

### What was wrong

Go binaries have no `.eh_frame`, so the agent gave them no table, and every Go frame was walked
by frame pointers. Go keeps frame pointers, so that mostly worked, except for one common case:
**a function with no stack frame**. A small leaf function without locals never pushes `rbp`:

```
main.leaf:
  lea    (%rax,%rax,2),%rax
  lea    0x1(%rax),%rax
  ret
```

A sample inside it still has the caller's `rbp`. The frame-pointer walk reads `[rbp + 8]`, which
is the return address of the **caller's caller**. The caller disappears, and the stack still
looks complete. It is the worst kind of wrong: nothing says it is wrong.

### Where Go keeps the truth: .gopclntab

The Go runtime needs to unwind its own stacks (for panics, the garbage collector, and its own
profiler), and it does not use frame pointers or DWARF for that. It uses a table it always
keeps in the binary, even with `-ldflags="-s -w"`: `.gopclntab`.

For every function, one of its tables, **pcsp**, says how far the stack pointer is below its
value at the function's entry, for every instruction. That is exactly what an unwinder needs:
the return address is at `rsp + sp_delta`, so

```
CFA = rsp + sp_delta + 8
```

Decoding `main.middle` of a real go1.26 binary:

```
0x47a7a0  sp_delta 0     entry: the return address is at rsp
0x47a7b0  sp_delta 8     after push %rbp
0x47a7ba  sp_delta 152   after sub $0x90,%rsp: the whole frame
0x47a842  sp_delta 8     the epilogue: add $0x90,%rsp
0x47a843  sp_delta 0     after pop %rbp, right before ret
```

`unwind/go_pclntab.zig` reads the header, the function table, and the pcsp tables (a pair of
varints per change: a zigzag value delta, then a pc delta). `Table.init_go` turns each range
into the same compact row the `.eh_frame` path makes. The kernel program does not know Go
exists: it sees rows.

### Three kinds of functions need care

The pclntab also has flags for each function, from Go's `internal/abi`, and two of them change
what a row means:

- **Top frame** (`runtime.goexit`, `mstart`, `rt0_go`): the bottom of a stack. Every goroutine's
  stack ends in `goexit`. Their rows are `end`: the walk is complete there.
- **Writes SP** (`systemstack`, `mcall`, `morestack`, and `nanotime1`, which switches stacks to
  call the vDSO): the stack pointer changes in ways pcsp cannot describe, so there is no honest
  row past it. Their rows are `unsupported`, and the walk stops there with a named reason.
  Go's own traceback stops at the same functions.
- **No pcsp table** (offset 0, which the first test run found): the same, `unsupported`.

And `rbp`: Go's prologue pushes it first (since Go 1.21), so once the frame has one word, the
caller's `rbp` is saved at `CFA - 16`. The rows say so, which keeps `rbp` right for any frame
further up that needs it.

### Does it work?

Without root, the test builds a Go program with the real toolchain, twice, and compares:

```
go: 11180 rows plain, 11180 rows stripped
```

Stripping removes the symbols and the DWARF, never the pclntab: the rows are identical. And
every byte of `main.leaf` has the row `CFA = rsp + 8`.

As root, it profiles the running program:

```
go e2e: 49 samples, 49 complete, 10 in leaf, 10 of those from middle
```

Every stack complete (down to `runtime.goexit`), and every sample in the frameless `leaf` has
`middle` as its caller: exactly the frame the frame-pointer walk used to lose.

### What is left

- **Size.** All binaries share one array of 262,144 rows. Go needs about 7.5 rows per function:
  the `go` tool (14 MiB) needs about 126,000, the compiler (24 MiB) about 221,000. A larger Go
  binary does not fit; it gets no table (`table_too_large` or `table_full` in the coverage) and
  is walked by frame pointers, as before. Making the array 2^20 rows (12 MiB) would fit almost
  any binary, at a cost in memory and in the verifier's search bound. That is the next step to
  weigh.
- **cgo.** A Go binary with C code: the pclntab covers the Go code, and the C code gets no rows.
  Merging its `.eh_frame` rows in is a small next step.
- **Go before 1.18** has another pclntab layout and is not read: frame pointers, as before.

## 4. Summary

| gap | fix | proof |
|---|---|---|
| CPUs online after start not sampled | one event slot per possible CPU, synced each report | 300 samples on the CPU that came back |
| over 128 libraries lost frames | 512 mappings, same kernel memory | the overflow test at 512 + 72 |
| frameless Go functions lost their caller | rows from `.gopclntab`, stripped or not | 10 of 10 samples in `leaf` from `middle` |
