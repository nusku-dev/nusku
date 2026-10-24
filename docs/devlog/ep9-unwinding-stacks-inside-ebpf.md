---
date: 2026-10-12
---

# Ep9: Unwinding Stacks Inside eBPF

In Ep7 we saw the first version of the on-CPU profiler. The eBPF program was about 80 lines: it asked the kernel for the user stack and the kernel stack, and counted them.

It worked, but only in the easy cases. Today we talk about the new `oncpu.ebpf.zig`, which is a lot bigger, and **why** it had to be.

The short version:

> The old program let the kernel decide how to read the stack. The new program reads the stack itself, using information Nusku prepares in advance.

That one change is why the file grew from 100 lines to more than a thousand.

## 2. A quick reminder: what is a stack?

When function `main` calls `handle_request`, and that calls `parse`, the CPU keeps the information about "where to return" on the stack.

```
high addresses
┌──────────────────────┐
│ main's frame         │
├──────────────────────┤
│ return address → main│
│ handle_request frame │
├──────────────────────┤
│ return address →     │
│   handle_request     │
│ parse frame          │  ← rsp points near here
└──────────────────────┘
low addresses
```

To print `main → handle_request → parse`, the profiler starts from where the CPU is now and walks upwards, frame by frame, collecting the return addresses. This walk is called **unwinding**.

The hard part is: **how do we know where the next return address is?**

## 3. The old way and why it broke

The old program called `bpf_get_stackid`. That helper walks the **frame pointer chain**:

```
rbp → [saved rbp][return address]
          │
          ▼
      [saved rbp][return address]
          │
          ▼
         ...
```

Every function saves the old `rbp` and sets a new one, so the frames form a linked list. Simple and fast.

But it has problems:

1. **It only works if the program keeps frame pointers.** Zig Debug and Go do. A C program built with `-O2` usually does not, because gcc uses `rbp` as a normal register to go faster. For those programs the stack comes back short or wrong.
2. **Stacks can be lost.** The stack-id table is a hash by stack content. Two different stacks can land on the same slot and the helper returns an error (`EEXIST`) instead of an id. So some samples simply disappear.
3. **The agent had to pause sampling** to read and clear the tables without losing data.
4. **No reason when a stack is short.** We could see a short stack, but not why.

For a profiler whose numbers should be **correct**, these are not small things.

## 4. How a program without frame pointers can still be unwound

Compilers already write down how to unwind every function. It lives in the `.eh_frame` section of the binary (it exists for exceptions and debuggers).

For each range of instructions it says something like:

> "While the pc is in this range, the return address is stored at `rsp + 8`."
> "After the function did `push rbp`, it is at `rsp + 16`."

The "place where the frame starts" is called the **CFA** (canonical frame address). The return address is always at `CFA - 8`.

So unwinding one step is:

```
pc, sp, bp   (where the CPU is)
     │
     ▼
find the rule for this pc          ← from .eh_frame
     │
     ▼
CFA = sp + N   (or bp + N)
     │
     ▼
return address = read memory at CFA - 8
     │
     ▼
caller: pc = return address, sp = CFA
```

Repeat until the bottom of the stack. No frame pointer needed.

> Why not let userspace do it?

Because userspace sees the sample too late. By the time the agent reads it, the process has moved on and the stack bytes are gone. The stack must be read **at the moment of the sample**, and that moment is inside the kernel. So the unwinder has to run in eBPF.

## 5. The big picture

The kernel program is small and restricted, so it cannot parse `.eh_frame` itself. The agent does the heavy work first and gives the program ready tables.

```
 ┌─────────────────────────── Agent (userspace) ───────────────────────────┐
 │                                                                          │
 │  /proc/<pid>/maps  ──►  which binaries and libraries are loaded, where   │
 │  .eh_frame         ──►  compact unwind rows for each of them             │
 │                                                                          │
 └───────────────┬──────────────────────────────────────────────────────────┘
                 │ writes tables into BPF maps
                 ▼
 ┌─────────────────────────── Kernel (eBPF) ───────────────────────────────┐
 │                                                                          │
 │  perf sample (99 Hz) ──► oncpu.ebpf.zig                                  │
 │                              │ read registers                            │
 │                              │ find rule for pc   (tables)               │
 │                              │ read stack memory, step to caller         │
 │                              │ repeat, up to 128 frames                  │
 │                              ▼                                           │
 │                    stack hash ──► counts map  (how many times)           │
 │                              └──► ring buffer (the frames, only once)    │
 └───────────────┬──────────────────────────────────────────────────────────┘
                 │ agent reads counts and ring
                 ▼
          server: symbolize addresses → function names → report
```

So the work is split in two:

- **Userspace** is good at parsing files, so it prepares the tables.
- **eBPF** is good at being at the right place at the right time, so it only does lookups and reads.

## 6. The tables

The tables are made as small as possible, because BPF memory is limited and the lookup must be fast.

| Struct | Size | What it holds |
|---|---:|---|
| `Row` | 12 bytes | From this pc on: where the CFA is (`sp + N` or `bp + N`) and where the old `rbp` was saved |
| `Module` | 24 bytes | One binary or library: where its rows start, how many, address range |
| `Mapping` | 32 bytes | One memory region of one process: start, end, load bias, which module |
| `ProcessEntry` | about 4 KiB | Up to 128 mappings of one process, sorted by address |

And three maps hold them: `unwind_rows` (all rows in one array, about 3 MiB), `unwind_modules`, `unwind_procs` (by process id).

Finding the rule for an address is two small binary searches:

```
runtime address (ip)
      │
      ▼
 search the mappings of the process        (at most 8 steps)
      │  → which library is this?
      ▼
 ip - bias = address inside the file
      │
      ▼
 search the rows of that module            (at most 19 steps)
      │  → the last row that starts at or below this address
      ▼
 the rule for this instruction
```

**Why one big array for the rows?** The verifier (the kernel checker from Ep5) looks at every map lookup. A lookup inside every step of a binary search would be very expensive to check. One pointer, taken once, then indexing, is much cheaper.

## 7. Living inside the verifier limits

The BPF program has hard limits: a 512 byte stack, no unbounded loops, and a limit on how much code the verifier will accept. Walking 128 frames in one run does not fit.

So the program works in small pieces:

```
run 1: frames 1..4    ─┐
run 2: frames 5..8     │  each run ends with a "tail call"
run 3: frames 9..12    │  to the same program
 ...                  ─┘
run N: stop           → finish
```

A **tail call** jumps to another BPF program (here, itself) without growing the stack. The kernel allows about 33 of them in a chain, so up to 34 runs, which is enough for 128 frames at 4 per run.

But every run starts with an empty stack, so where does the walk remember where it was? In a **per-CPU map entry**: current pc, sp, bp, how many frames so far, the hash, the counters. Each CPU has its own copy, so no locks are needed.

## 8. The first frame is special

When the timer fires, the CPU can be in two places:

- **user code**: the registers in the sample are the process registers. Good.
- **inside the kernel** (a syscall, a page fault): the registers in the sample are kernel registers. Useless for a user stack.

So the program does not use the sample registers. It reads the **saved user registers of the task** (`bpf_task_pt_regs`), which are always the user ones. The sample is only used to learn which mode the CPU was in.

There is one more detail. If the sample was in the kernel and the two bytes before the user `ip` are `0f 05` (the `syscall` instruction), then that `ip` is already a **return address**, not the instruction being executed. Return addresses must be looked up with `pc - 1` (a call can be the last instruction of a function, and then the return address belongs to the next function). The program remembers this in a flag.

For kernel-mode samples the program also asks `bpf_get_stack` for up to 32 kernel frames and puts them after the user frames. That is how a `read` syscall shows its kernel part.

## 9. When there is no rule

Not everything has a row. For those cases there are two paths:

- **Frame pointer fallback:** if the address is in a module with no usable row, but `rbp` looks sane, follow the old chain (`[rbp]` is the saved `rbp`, `[rbp+8]` is the return address). It refuses values that look wrong (zero, below `sp`, not aligned).
- **Stop:** if nothing works, the walk ends.

And here is the idea that I like most in this design: **a walk never just ends. It always ends with a named reason.**

| Reason | Meaning |
|---|---|
| `end` | reached the real bottom of the stack |
| `truncated` | hit the 128 frame limit |
| `no_module` | the first address is in no known mapping |
| `no_function` | tables exist but no function covers this pc |
| `unsupported` | a rule type we do not handle |
| `outside_stack` | reading the stack memory failed |
| `stuck` | the stack pointer did not move up (loop guard) |
| `invalid_address` | a return address that points nowhere |
| `bad_frame_pointer` | the fallback refused the frame pointer |
| `chain` | tail call limit reached |

Every reading of memory uses `bpf_probe_read_user`, which returns an error instead of crashing when the address is bad. So a broken stack costs one sample with a reason, never a crash.

## 10. Counting without losing anything

After the walk the program has the frames. Sending every sample's frames to userspace would be too much data at 99 samples per second per CPU. But most samples are the same stacks again and again.

So each stack gets a 64 bit **hash** (every frame, plus the stop reason, mixed with splitmix64). Then:

```
walk finished
      │
      ▼
 hash → key {hash, pid}
      │
      ▼
 key already in the counts map?
      │
  yes │                         no
      ▼                          ▼
 add 1 to its count       send frames to the ring buffer
 (that's all)                    │
                                 ▼
                          insert key with count 1
```

So the frames of a stack travel to userspace **once**, the first time it is seen. After that a sample costs one lookup and one add.

The order matters: **the record goes into the ring buffer before the key is inserted.** If the ring is full, the key is not inserted, and the next sample of that stack tries again. That way a count never exists without its frames.

And everything is counted, so we can check the program against itself:

```
walks      = repeats + sent + dropped
sum(counts) = walks - dropped - map_full
```

If these two lines do not hold exactly in a test, there is a bug. A sample can be counted or it can be in a named loss counter. It cannot vanish.

The counts only grow. The agent takes snapshots and uses the difference between two snapshots as a time window. It never deletes anything while sampling and never pauses.

## 11. What changed, in one table

| Old | New | Why |
|---|---|---|
| `bpf_get_stackid` | own walk using `.eh_frame` rows | works without frame pointers |
| `stacks` map with ids | frames in a ring buffer + hash | no collisions, no `EEXIST` |
| `counts` keyed by two ids | counts keyed by stack hash | the counts add up exactly |
| pause, read, delete | cumulative counts and snapshots | no pause, no race |
| short stack, no reason | 10 named stop reasons | every incomplete stack has a cause |
| one run | 4 frames per run, tail calls | fits the verifier |
| registers from the sample | saved registers of the task | correct start inside syscalls |

## 12. Does it work?

We check it against programs where we know the true answer.

For a C service with several jobs of known CPU weight, every job came out within one percentage point of the real value. Only 0.06% of the stacks were incomplete, and each one has a named reason from the table above.

Not done yet, and I want to be honest about it:

- **Go.** Some Go assembly functions use `rbp` as normal data and some have no frame, so the fallback cannot follow them. Go needs its own source of rows (`.gopclntab`).
- **Compiler tail calls** can remove a frame legitimately (`jmp` instead of `call`). That is not a bug in the profiler, the frame is really not there.
- Overhead compared to other profilers is not measured yet.

## 13. Summary

The new `oncpu.ebpf.zig` does one job: **read the stack correctly, at the moment of the sample, for any program, and account for every sample.**

- The agent prepares compact unwind tables from `.eh_frame`.
- The eBPF program finds the rule for each address, reads the return address, and steps up, 4 frames per run with tail calls.
- Frame pointers are only a fallback.
- Every walk ends with a named reason.
- Stacks are identified by a hash, sent once through a ring buffer, and counted in a map.

The next episode will be the part that happens after this: how the agent reads the counts and the ring, and how the server turns addresses into function names.
