---
date: 2026-11-05
---

# Ep18: The Whole Pipeline, From a Sample to a Named Profile

Until this episode, Nusku had an agent that collected stacks of raw addresses, and the start of
a server. Now the whole path works, and it is one command:

```
sudo nusku prof --exec ./app --duration 5
```

It launches the program, samples it 99 times a second, unwinds every sample, sends the stacks
and the binaries' symbols to a server in the same process, names every frame, and prints this:

```
  nusku  c-app [pid 312243] · 5.0 s · 495 samples at 99 Hz · duration reached

  Top functions  by self time, 5 of 5 that ran
    SELF               TOTAL              FUNCTION
     49.4% ████▉        49.4% ████▉       hot_leaf  c-app
     30.3% ███          30.3% ███         recurse  c-app
     15.7% █▌               –             [libc.so.6]
      4.0% ▍             4.0% ▍           compare  c-app
      0.4%              20.2% ██          cold  c-app

  Call tree  outermost frame first, hiding branches under 1.0%
  100.0%  _start  c-app
  100.0%  __libc_start_main  libc.so.6
  100.0%  [libc.so.6]
  100.0%  main  c-app
  100.0%  run
   49.4%  ├─ hot
   49.4%  │  hot_leaf
   30.3%  ├─ warm
   30.3%  │  recurse ↻
   20.2%  └─ cold  self 0.4%
   19.7%     qsort_r  libc.so.6
   19.7%     [libc.so.6] ↻  self 15.7%
    4.0%     compare  c-app
```

That program was written to spend 50% of its time in `hot_leaf`, 30% in `recurse` and 20% in
`cold`. The profile says 49.4%, 30.3% and 20.2%.

This episode follows one sample through every stage, says what each stage keeps and why, and
then covers what went wrong on the way: four bugs that only real programs showed, and how the
results are now checked against programs whose profile is known in advance.

## 1. The map

```
 the target process
      │  a CPU timer fires, 99 times a second, on every CPU
      ▼
 ┌── kernel ───────────────────────────────────────────────────────────────┐
 │ BPF program: walk the user stack with the unwind tables, take the       │
 │ kernel stack, count it. A new stack goes to the ring buffer once.       │
 └─────────────────────────────────────────────────────────────────────────┘
      │  ring buffer + counts map
      ▼
 ┌── agent (a thread) ─────────────────────────────────────────────────────┐
 │ tick (≤100 ms): drain the ring, send ≤4 chunks of a binary              │
 │ report (every interval): regions + kernel identity + stacks → Report    │
 │ offer: every new build ID → binary_known? → begin, chunk…, end          │
 └─────────────────────────────────────────────────────────────────────────┘
      │  on_report(Message)            │  binary hooks
      ▼                                ▼
 ┌── server ───────────────────────────────────────────────────────────────┐
 │ store: a ring of windows per target         uploads → build queue       │
 │                                              builder thread → tables     │
 │ query: windows → regions → file offsets → names → merged stacks         │
 └─────────────────────────────────────────────────────────────────────────┘
      │  Profile
      ▼
 ┌── CLI ──────────────────────────────────────────────────────────────────┐
 │ live view while it runs; then the report, the call tree, folded stacks  │
 └─────────────────────────────────────────────────────────────────────────┘
```

Three threads do the work: the agent's, the server's builder, and the CLI's main thread. They
meet in one place, the server, behind one lock.

## 2. The kernel: one sample

A perf event per CPU fires 99 times a second (an odd rate, so it does not beat in step with
timers in the program). Each time it runs the BPF program on that CPU, in the context of
whatever thread was running.

If that thread belongs to the target, the program:

1. walks the **user** stack, up to 128 frames, with the unwind tables the agent wrote into BPF
   maps (Ep9). Each row says, for a range of code, where the caller's frame is: how to find the
   return address and the saved `rbp`. Where there is no row, it falls back to frame pointers.
2. takes the **kernel** stack, up to 32 frames.
3. notes two flags. `leaf_is_return`: the sample was taken inside a system call, so even the
   first user frame is a return address (Ep17). `complete`: the walk reached the outermost
   frame rather than giving up.
4. counts it. A stack it has never seen goes to the ring buffer once, with its frames; a stack
   it has seen only bumps a counter in a map. Most samples are repeats, so the ring stays
   small (the tests show 93 stacks sent for 1204 walks).

The kernel side does nothing else. It does not name anything, and it never reads a file.

## 3. The agent: from samples to reports

The agent is `agent.profile`, a loop on its own thread (Ep15). It does two kinds of work.

**Every tick** (at most 100 ms), it drains the ring buffer into its own table of stacks, so
the kernel never drops a sample for want of room. It also sends a little of a binary, if one is
on its way (see below).

**Every report** (`--interval`, 1 s by default), it builds a `Report`:

| Part | What it is | Why the server needs it |
|---|---|---|
| stacks | each distinct stack, its frames, its samples, its flags | the profile itself |
| regions | the executable mappings: start, end, file offset, path, build ID | to turn an address into a place in a file |
| kernel | release, build ID, `_text` address | to name kernel frames (not done yet) |
| counts | samples, samples lost, unwind coverage | to say what the profile is missing |

The regions are why an address can be named at all. `0x7f3a1245c1a3` means nothing outside
the process. But it is inside a region: `/usr/lib/libc.so.6`, mapped at `0x7f3a12400000` from
file offset `0x28000`. So it is file offset `0x5c1a3` of the libc whose build ID is
`ab12...`. That pair, **(build ID, file offset)**, is the same in every process and every run,
on every machine (Ep17).

### Binaries go once per build ID

The server needs each binary's symbols, but only once per build ID, whatever the number of
processes or runs that map it. After each report, the agent's offer looks at the regions for
build IDs it has not seen this run, and queues them (16 at a time, 256 per run). On ticks, it
works through the queue:

```
binary_known(id)?   yes → nothing to do
                    no  → open the file as the target sees it, check the build ID,
                          binary_begin(header) → binary_chunk × N → binary_end
                          (binary_abort if anything stops it)
```

The header says where the executable segments are and how big each of the four sections is
(`.symtab`, `.strtab`, `.dynsym`, `.dynstr`). The bytes follow in chunks of 256 KiB, at most
four per tick, so a 2 GiB binary costs more ticks, never more memory, and never delays the
drain of the ring.

The vDSO is sent from the agent's own copy: it has no file.

## 4. The server: keeping, receiving, naming

The server lives in `server/`. Everything in it is bounded when it starts.

### 4.1 Windows

Each report arrives through `ingest` and is copied into the target's **window ring**: a fixed
number of slots (enough for the whole run, up to 3600), each a fixed size (128 KiB). A full
ring writes over its oldest window. Nothing is allocated per report.

A target outlives its run, so its windows can still be queried after it stops. When the store
is full, the oldest *finished* target makes room; a running one is never dropped.

### 4.2 Receiving a binary

```
binary_begin   upload_start: claim the build ID, reserve the bytes from the upload budget
               Upload.begin: one buffer, as big as the header said
binary_chunk   in order, no gap, never past what the header said
binary_end     Upload.end → a Received → the build queue (32); the agent goes on at once
                                            │
               builder thread:  SymbolTable.init → Binaries.put
```

What arrives is untrusted. The header fixes the size of everything, so the upload allocates
once and checks each chunk against it; anything that does not fit ends the upload. Fuzz tests
throw random sequences of calls at it.

The claim means two runs of the same program do not both send libc: while one sends it,
`binary_known` says yes to the other. The budget (1 GiB for all uploads together) is held from
the first chunk until the table is built, because the bytes are in memory until then.

The table is built on a thread of its own because building means sorting every function of the
file, and the run's thread is the agent's loop: while it waits, nobody drains the ring. A table
too big to keep is remembered as refused, so no run sends it again.

### 4.3 The symbol table

From `.symtab` if the file has one, else `.dynsym`. It keeps the functions defined in the file
and inside an executable segment, converts each address to a file offset with the segments of
the header (`offset = vaddr - p_vaddr + p_offset`), and sorts them: 16 bytes per function, plus
the names. A lookup is a binary search.

The tables are kept by build ID, 1024 of them or 256 MiB, whichever comes first, and the least
recently used go when a new one does not fit. A table counts as used when a query names an
address with it, and when a window arrives that needs it.

### 4.4 A query

```
profile(target, from, to)
  windows_copy      under the lock: the windows of the time range
  for each window   its regions, checked once (sorted, apart)
    for each frame  region (binary search) → file offset (minus one for a return address)
                    → name: the query's cache, or the table under the lock
  merge             the same path through the same functions is one stack
```

Two details make it right and fast.

**Minus one.** Every user frame after the first is a return address: it points after the call
instruction, sometimes into the next function. The call is at `address - 1`.

**A cache in front of the tables.** The same addresses come back in almost every stack: every
stack through a call site has the same return address. Each query keeps 1024 recent answers by
(build ID, file offset). That pair names the same function forever, so a cached answer is right
even if the table goes away during the query. The lock is taken only for a lookup the cache
does not answer, so reports keep arriving while a query runs.

## 5. The CLI

`nusku prof` puts the pieces together in one process (`src/clients/local.zig`): a server, a
controller, and the agent on a thread of the controller.

**While it runs**, on a terminal, it draws the header and the top functions every report, over
the last view, like `top`. To a pipe or a file it draws nothing until the end. The main thread
does not block on the run; it looks every 50 ms whether the run is over.

**Ctrl-C stops the run, not the program.** The handler triggers the run's cancel (one write to
an eventfd: safe in a signal handler), the agent stops at its next wait, and the report of what
was sampled until then is printed. The handler stays until the program exits: under `sudo`, one
Ctrl-C can arrive twice, and the second must not kill the program before it prints.

**At the end**, it waits for the builder to finish the last tables, asks for the profile of the
whole run, and prints:

- **top functions**: self time (the function was running) and total time (it was on the
  stack, counted once per stack however deep a recursion). Only the ones that ran: those that
  only called others are in the tree. Code without names shows by its binary, `[libc.so.6]`,
  with no total, since that label lumps unrelated code together.
- **the call tree**, from the outermost frame in. A path that does not branch stays in one
  column; only a branch indents. Recursion folds into one line (`↻`). Branches under
  `--cutoff` (1%) are summed into one line.
- with `--folded file`, the stacks in the folded format (`main;run;hot;hot_leaf 245`), which
  flame graph tools read.

## 6. How to read the output

The report has three parts. Here is each line of the one at the top of this episode, and what
it means.

### 6.1 The header

```
  nusku  c-app [pid 312243] · 5.0 s · 495 samples at 99 Hz · duration reached
```

| Part | Meaning |
|---|---|
| `c-app` | the process's name: the program's file name with `--exec`, its `comm` (what `ps` shows) with `--pid` |
| `[pid 312243]` | its process id |
| `5.0 s` | how long the run took, from start to stop |
| `495 samples` | how many times a CPU was caught running the process |
| `at 99 Hz` | how often each CPU is looked at: 99 times a second |
| `duration reached` | why it stopped: `duration reached` (`--duration`), `process exited`, or `interrupted` (Ctrl-C) |

**Samples are time.** At 99 Hz, one sample is about 10 ms of CPU. 495 samples in 5 seconds is
5 seconds of CPU: the program kept one CPU busy the whole time. A program that sleeps or waits
gets few samples, however long it runs: this is an on-CPU profile, it shows where the CPU time
went, not where the program waited. A process with four busy threads gets about four times as
many samples as seconds × 99.

Two lines may follow the header, in yellow. They mean the profile is missing something:

```
  ! 12 samples lost: the kernel's buffer was full
  ! 3 reports lost: too big to keep
```

The first counts samples the kernel could not hand over in time; the second, whole reports
(about a second each, at the default `--interval`) that did not fit the server's window. The
shares below are of what was kept.

### 6.2 Top functions

```
    SELF               TOTAL              FUNCTION
     49.4% ████▉        49.4% ████▉       hot_leaf  c-app
      0.4%              20.2% ██          cold  c-app
     15.7% █▌               –             [libc.so.6]
```

Every share is of all the samples of the run.

- **SELF** is how often the function was the one running: the innermost frame of the sample.
  It is the time spent in the function's own code. The rows are sorted by it: the top row is
  where the CPU went.
- **TOTAL** is how often the function was anywhere on the stack: running, or waiting for a
  function it called. It is the time spent in the function *and everything under it*. A
  recursive function counts once per sample, however deep, so a total is never more than 100%.
- **The bars** draw the same share: ten blocks are 100%.
- **The dimmed name after the function** is the binary it is in (`c-app`, `libc.so.6`).

Read them together:

| Self | Total | What it means |
|---|---|---|
| high | high | the function does the work itself: `hot_leaf`, 49.4% and 49.4% |
| low | high | the function is expensive because of what it calls: `cold`, 0.4% of its own, 20.2% with its calls. Look under it in the tree |
| equal | equal | it calls nothing that takes time: a leaf |

Only functions that ran (self above 0) are in this table. Those that only called others
(`main`, `run`) are in the call tree.

**`[libc.so.6]`** is code of `libc.so.6` that has no name: a static function of a library
shipped without its full symbols. Its self time is real and counted. Its total shows `–`,
because all the unnamed code of a binary shares one label: here, glibc's start code and its
sort, two things that have nothing to do with each other, so a total of them would mean
nothing.

`by self time, 5 of 5 that ran` says how many functions are shown (`--top`, 20 by default) of
how many ran.

### 6.3 The call tree

```
  100.0%  _start  c-app
  100.0%  __libc_start_main  libc.so.6
  100.0%  [libc.so.6]
  100.0%  main  c-app
  100.0%  run
   49.4%  ├─ hot
   49.4%  │  hot_leaf
   30.3%  ├─ warm
   30.3%  │  recurse ↻
   20.2%  └─ cold  self 0.4%
   19.7%     qsort_r  libc.so.6
   19.7%     [libc.so.6] ↻  self 15.7%
    4.0%     compare  c-app
```

The tree is every stack merged, read from the outermost frame (`_start`, where the program
starts) in, to the innermost (where it was running). Each line is a function **on that path**:
the same function called from two places is two lines.

- **The percentage** is the line's total: how often the program was in that function, *by that
  path*. A line's children add up to it, less the line's own self time.
- **One column, no branch.** Lines in the same column with no `├─` are one path: `_start`
  called `__libc_start_main`, which called `main`, which called `run`. They all show 100%:
  every sample went through all of them.
- **`├─` and `└─` are a branch**: the function above called more than one function that took
  time. `run` called `hot`, `warm` and `cold`; `└─` marks the last of them. `│` continues the
  line of a branch that has more below.
- **`↻`** is recursion: the function called itself, maybe many times, and the levels are one
  line. `recurse ↻` is `recurse` eight deep.
- **`self 0.4%`** is the line's own time, shown where the function also calls others: `cold`
  spends 0.4% in its own code and the rest in `qsort_r`.
- **The dimmed binary** is shown where it changes along the path: `qsort_r` is the first line in
  `libc.so.6`, and `compare` is back in `c-app`. The path crossed into libc and came back out:
  `qsort` called the program's own `compare`.
- **`… 3 more`** sums the branches under `--cutoff` (1% by default), so small ones do not hide
  the large ones. `--cutoff 0` shows everything.
- **`[walk stopped]`** is where stacks go whose walk did not reach the outermost frame (a
  function the unwinder had no rule for, and no frame pointer either). Their inner frames are
  right; what called them is unknown, so they are not put under a caller they may not have.

**How to use it.** Start at the top functions, pick a row with a high self time, and find it in
the tree: the lines above it say how the program got there. Or start at the top of the tree
and follow the largest percentage down at every branch: that is the hottest path.

### 6.4 While it runs

On a terminal, the header and the top functions are drawn while the run goes, once per report
(`--interval`), over the last view. The header then ends with `live · Ctrl-C to stop`. The
numbers are of everything sampled so far, not of the last second. When the run ends, the view
is replaced by the full report, with the tree. To a pipe or a file, only the final report is
written.

### 6.5 Colors

On a terminal (`--color auto`, unless `NO_COLOR` is set):

- **red**: a quarter of the time or more;
- **yellow**: a tenth or more, and the warnings;
- **normal**: 1% or more;
- **dim**: less than 1%, the binaries, and the tree's lines.

### 6.6 Folded stacks

`--folded out.folded` also writes every stack on one line, for flame graph tools:

```
_start;__libc_start_main;[libc.so.6];main;run;hot;hot_leaf 245
_start;__libc_start_main;[libc.so.6];main;run;warm;recurse;recurse;recurse 150
```

The frames go from the outermost in, joined by `;`, then the number of samples. Recursion is
not folded here: tools count it themselves. A stack whose walk stopped starts with
`[incomplete]`. `flamegraph.pl out.folded > flame.svg` draws it.

## 7. What the real programs found

Unit tests had passed for weeks. Real programs found four bugs in an afternoon.

### 7.1 musl's C has no unwind tables

A Zig program spinning on `clock_gettime` gave stacks that stopped after two frames: the
vDSO, then `__clock_gettime`, then nothing.

musl is built without unwind tables (`-fno-asynchronous-unwind-tables`, to stay small), so its
functions have no `.eh_frame` entry. And musl's `clock_gettime` uses `rbp` as an ordinary
register (it keeps the clock id in it), so the frame pointer fallback read garbage.

An unstripped binary still has the same information in `.debug_frame`, the DWARF standard's
own section. The two differ in three small ways: how a CIE is marked (`0xffffffff` instead of
0), how an FDE points at its CIE (an offset from the section start instead of a distance back),
and that addresses are never relative. The reader now takes both, and a module's table is its
`.eh_frame` entries plus the `.debug_frame` entries for code that `.eh_frame` does not cover.
A `.debug_frame` that cannot be read is ignored: a module never loses what it had.

### 7.2 The vDSO's code has no names

The leaf of those stacks was `?`, though the vDSO's symbols were sent. The vDSO exports each
function as a stub of one instruction that jumps to the real body, and the kernel strips every
other symbol:

```
__vdso_clock_gettime   0xe40, 5 bytes:   jmp 0xab0
the real body          0xab0 .. 0xe00    no symbol
```

A sample is nearly always in the body. So the agent writes a small `.symtab` for the vDSO: the
exported symbols, plus each body under the name of the stub that jumps to it, sized by the
vDSO's own unwind entry for it. The server needed no change: it prefers `.symtab` anyway.

### 7.3 Chrome's renderers see no files

Profiling a Chrome renderer gave 91 mappings out of 92 without an unwind table, and no names.
Chrome's sandbox runs renderers chrooted into an empty directory:

```
$ readlink /proc/9247/root
/proc/8963/fdinfo
```

The agent opened every file as the process sees it, through `/proc/<pid>/root/<path>`, and
inside that root there is nothing. But the kernel also gives every mapping of a process as a
file, whatever its root: `/proc/<pid>/map_files/<start>-<end>`. When the path does not open,
the agent now opens the mapping itself (it needs `CAP_SYS_ADMIN`, which root has). The build ID
check still says it is the right file.

### 7.4 Go hides its build ID from the program headers

A Go program was unwound perfectly, and not one frame was named. The agent finds a build ID
by reading the `PT_NOTE` program headers. Go's linker writes two notes, its own and the GNU one
right after it, but its only `PT_NOTE` header covers the first:

```
NOTE  0x000f78  size 0x64        .note.go.buildid
                                 .note.gnu.build-id at 0xfdc: outside it
```

With no build ID, the binary was never offered. Now, when the program headers lead to no ID,
the agent reads the section headers (a few KiB at the end of the file) and looks in the note
sections. Every Go binary built by the standard toolchain had this.

### 7.5 Smaller ones

- An aborted upload kept its buffers, and the next binary's `begin` found it still open: two
  binaries lost for one failure. `binary_abort` now drops it.
- A function at the very last file offset, with no size, overflowed a `+ 1`. Untrusted
  segments can put one there. Found while writing the fuzz test.
- A Zig binary has no GNU build ID unless asked (`--build-id`), so nothing in it can be named.
  Not fixed yet: the fallback identity in section 10.

## 8. Checking the numbers

Unit tests say each part does what it says. They do not say the profile is true. For that,
`testing/` has three small programs, in C, Go and Zig, that do the same thing by design:

```
 50%  run → hot  → hot_leaf               a plain loop
 30%  run → warm → recurse × 8            a recursion, spinning at the bottom
 20%  run → cold → library sort → compare  through libc's qsort, Go's sort.Slice, std.mem.sort
```

Each round of 100 ms is split by the clock, not by work, so the shares are the same on any
machine. Each program tests something different: C is built without frame pointers (unwinding
through `.eh_frame`, libc's too), Go has no `.eh_frame` (the pclntab), Zig is built in release
mode. Each has an `expect.txt`:

```
samples   >300
complete  >95          # at least 95% of the samples have their whole stack
self  hot_leaf 50      # ±5 points
self  recurse  30
total cold     20
total compare  >1      # the walk went into the library and came back
total run      >95
```

`make check` builds everything, profiles each program for 5 seconds, and checks the folded
stacks (not the pretty report, so the display can change freely):

| | hot_leaf | recurse | cold | complete |
|---|---|---|---|---|
| designed | 50% | 30% | 20% | 100% |
| C | 49.2% | 29.8% | 20.2% | 100% |
| Go | 48.0% | 29.2% | 20.0% | 98.4% |
| Zig | 47.0% | 30.1% | 20.4% | 100% |

Go's `run` is at 97.9% rather than 100%, most likely the runtime's own threads (the garbage
collector, the scheduler's monitor): they are part of the process, so they are sampled too, but
they are not under `main.run`. That would be true time, not an error.

## 9. Logs

The agent and the server log the same way, each under its own scope (`agent`, `server`), and
both are quiet until a program installs a logger:

- **err**: something failed: the server did not start, a run failed.
- **warn**: something was lost or refused, with what it costs: "window too big to keep: its
  samples are lost", "no symbol table: its frames will stay unnamed".
- **info**: life cycle, with a summary at the end: started, stopped, how many, how long.
- **debug**: one line per binary, per table, per query.

Nothing logs per sample or per frame. A warning that could repeat every report is logged once.
Binaries are named by their path, the way a person knows them, and build IDs are shown in hex,
the way `readelf` shows them.

## 10. What is not done yet

- **Kernel frames** are counted but not named: the identity is sent, the symbols are not.
- **Binaries without a build ID** (plain Zig builds, some others) cannot be named. A fallback
  identity computed by the agent, from the headers and the size, would cover them.
- **Stripped Go binaries** keep their unwinding (the pclntab) but lose their names: the
  pclntab has names too, and the agent does not send them yet.
- **Static functions of a stripped library** (glibc's sort internals, `[libc.so.6]` above)
  stay unnamed without its debug symbols.
- **Nothing is kept on disk**: a restarted server asks for every binary again.
- **One process at a time**, in one process: the agent and the server are already separated by
  hooks shaped like a network stream, so a remote agent is the next big step.

## 11. Summary

- A sample is a stack of addresses, walked in the kernel with tables the agent built. The agent
  counts them and sends them every interval, with the regions that say which file each address
  is in.
- Each binary's symbols go once per build ID, in bounded chunks, only when the server asks. The
  server checks everything, builds the tables on its own thread, and keeps them within fixed
  limits.
- Naming happens when a profile is asked for: region, file offset, symbol, through a cache keyed
  by (build ID, file offset), and the stacks are merged by function.
- `nusku prof` shows it live and then prints the functions and the call tree, or folded stacks
  for flame graphs.
- Real programs found what unit tests could not: musl without unwind tables, the vDSO's stubs,
  Chrome's sandbox, Go's notes. Three small programs whose profile is known in advance now check
  every change: within a point or two of the truth.
