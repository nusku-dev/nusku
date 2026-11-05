---
date: 2026-11-05
---

# Ep17: What the Agent Sends So an Address Gets a Name

Until now the agent sent stacks of raw addresses, such as `0x7f3a1245c1a3`. A person wants
`parse_header` instead. The work of turning one into the other is called **symbolization**, and
it happens on the server, not on the profiled machine. This episode covers what the agent
collects so the server can do it:

- each piece of information
- where the agent gets it
- why the server cannot do without it
- how it fits into the agent's loop from Ep14 and Ep15

The short version:

> An address alone means nothing outside the process it came from. To name it, the server needs
> to know **which file** the address is in, **where** in that file, and **what that file's
> symbols are**. The agent sends all three: regions with every report, and each binary's
> symbols once per build ID.

## 1. Why an address cannot be named on its own

An address is only meaningful inside the process it was taken from, and only for that run:

- **ASLR.** The kernel loads each library at a random base, so `libc` is at `0x7f3a12400000` in
  one process and at `0x7f91c0200000` in the next. The same function has a different address in
  every process.
- **Many files.** A process maps its executable, dozens of libraries, the vDSO and anonymous
  memory (JIT code). An address belongs to exactly one of them.
- **Files change.** A package upgrade can replace `/usr/lib/libc.so.6` while the process still
  runs the old one. The path then leads to the wrong file.
- **The server is elsewhere.** The server may run on another machine (gRPC later). It cannot
  read the target's `/proc`, and it cannot open the target's files.

Each of these problems decides one of the pieces below.

## 2. The rule: symbols are keyed by (build ID, file offset)

The server never looks up a raw address. It turns each address into two values that stay the
same across processes and runs:

```
address 0x7f3a1245c1a3
   │  which region holds it?                  ← regions (with every report)
   ▼
region /usr/lib/libc.so.6, build ID 7a3c…, start 0x7f3a12400000, offset 0x28000
   │  file offset = address - start + offset
   ▼
(build ID 7a3c…, file offset 0x841a3)          ← the same in every process, every run
   │  file offset → virtual address            ← the binary's segments
   ▼
vaddr 0x841a3 - p_offset + p_vaddr
   │  look it up in the symbol table           ← the binary's .symtab/.dynsym
   ▼
"parse_header"
```

- **The build ID** is a hash the linker writes into the ELF file. Two files with the same
  build ID are the same build, whatever their path. It answers "which file" even after an
  upgrade, and even on another machine.
- **The file offset** does not depend on where the file was loaded, so ASLR has no effect on it.

So one symbol table serves every process and every run of a binary. A server profiling a
hundred copies of the same service stores its symbols once.

## 3. What the agent collects

| Piece | Where the agent gets it | When | Why the server needs it |
|---|---|---|---|
| Regions: start, end, file offset, path, inode | `/proc/<pid>/maps`, executable mappings only | every report | to find the file of an address and the offset in that file |
| Build ID of each file region | the ELF notes in the first 64 KiB of the file | the first time a file is seen | which binary it really is, whatever the path |
| Build ID of `[vdso]` | the agent's own copy of the vDSO | at start | the vDSO has no file; without an ID it could never be matched |
| The binary itself: segments, `.symtab`, `.strtab`, `.dynsym`, `.dynstr` | the file, through `/proc/<pid>/root` | once per build ID per run, only if the server asks | the function names, and the segments to turn file offsets into symbol addresses |
| Kernel identity: release, build ID, `_text` address | `/proc/sys/kernel/osrelease`, `/sys/kernel/notes`, `/proc/kallsyms` | once per run | to name kernel frames despite KASLR |
| Stack flags: `leaf_is_return`, `complete`, `kernel_truncated` | the kernel program, per stack | every sample | to look up the right instruction, and to know how much of a stack to trust |

The subsections below follow the table row by row.

### 3.1 Regions (`target/process_maps.zig`, `target/regions.zig`)

A region is one line of `/proc/<pid>/maps` with execute permission:

```
7f3a12428000-7f3a125bd000 r-xp 00028000 08:02 1835023  /usr/lib/libc.so.6
start        end               offset         inode    path
```

- `start` and `end` say which addresses are in this file.
- `offset` says which byte of the file `start` is. Without it the file offset could not be
  computed: a library's code is usually not at offset 0, because the kernel maps each segment on
  its own.
- `path` names the file for display, and for the agent to open it. The server never opens it.
- `inode` tells two files with the same path apart, so the agent can reuse what it already knows
  about a file.

The agent reads the regions again at every report, because a target loads libraries while it
runs (`dlopen`, plugins). The regions go out **with** each report. A report's addresses then
always resolve against the regions of their own window, even when a library was loaded or
unloaded in between.

Only executable mappings are kept: a sampled instruction or a return address can only be in
code.

### 3.2 Build IDs (`target/build_id.zig`)

The GNU build ID is an ELF note (`NT_GNU_BUILD_ID`, usually a 20-byte SHA-1). The agent reads
the first 64 KiB of the file, where the ELF header, the program headers and the note segments
are for practically every binary, and takes the ID from there. It never reads the whole file
for this.

Three details make it cheap and correct:

- **Read once.** `regions.build` reuses the ID of a region of the same file, first from the
  table it is building, then from the previous report's table. A steady target costs no file
  reads at all after the first report.
- **Read as the target sees it.** The path is opened as `/proc/<pid>/root/<path>`, so a file
  inside a container is found even when the agent runs outside the container.
- **A missing ID never fails a profile.** Many Zig and Go binaries have no build ID, and the
  region then just has none. Its addresses stay unnamed for now; a fallback identity computed by
  the agent is planned.

### 3.3 The vDSO's build ID (`target/vdso.zig`, `regions.vdso_mark`)

The `[vdso]` region has no file, so there is nothing to read a build ID from. But every 64-bit
process on one kernel maps the same vDSO image, and the agent already copies its own at start
for the unwinder (Ep13). That copy has its build ID.

`vdso_mark` gives that ID to the target's `[vdso]` region when the sizes agree. A 32-bit
target maps another vDSO of another size, and gets no ID rather than a wrong one. Without this,
every sample inside `clock_gettime` would stay an address forever.

### 3.4 The binary: segments and symbol sections (`symbols/`)

The server must parse the symbol table of each binary, and it cannot open the binary. So the
agent sends the parts it needs:

- **The executable `PT_LOAD` segments** (`offset`, `vaddr`, `filesz`). Symbols are written as
  virtual addresses, but the server holds file offsets. The segment whose file range holds the
  offset converts it: `vaddr = offset - p_offset + p_vaddr`.
- **`.symtab` and `.strtab`**: every function, with its name, when the binary is not stripped.
- **`.dynsym` and `.dynstr`**: the exported functions. A stripped library keeps these, so its
  public functions still get names.
- **Section sizes**, in the header, so the server knows how much is coming. A section the file
  lacks has size 0.

Nothing else is sent: no code, no data, no debug info yet. The agent does not parse the symbol
tables. It reads only the ELF headers, to find where the sections are, and streams the bytes.
The server parses them and treats them as untrusted.

### 3.5 Kernel identity (`target/kernel.zig`)

Kernel frames have the same problem as user frames:

- **`release`** (`6.8.0-45-generic`) says which kernel it is, for a person and as a fallback to
  find symbols.
- **`build_id`**, read from `/sys/kernel/notes`, identifies the exact kernel image, the key to
  find its `vmlinux` or symbol file.
- **`text_address`** is where `_text` is at run time, from `/proc/kallsyms`. The kernel moves
  itself at boot (KASLR), so a kernel address is resolved as `address - text_address`, an
  offset from `_text` that stays the same across boots. Reading it needs `CAP_SYSLOG`. Without
  it the field is null, and the agent logs why.

This is read once per run: the kernel cannot change under a running agent.

### 3.6 Stack flags (`bpf/kernel/cpu.bpf.zig`)

Three flags travel with each stack, and each one changes what the server does with it:

- **`leaf_is_return`.** Every user frame after the first is a return address: it points to the
  instruction *after* the call, which may already be the first instruction of the next
  function. The symbolizer must look up `address - 1`. The first frame is normally the exact
  instruction that was running. When the sample hit while the thread was inside a system call,
  though, the first user address is where the `syscall` instruction returns to. The kernel
  program checks this: it reads the 8 bytes before the user pc, and checks whether the last two
  are the `syscall` instruction (`0f 05`). Without this flag, time spent in `read()` would be
  charged to the function after the call site.
- **`complete`** (the walk reached the outermost frame). A UI can then show cut stacks as cut,
  instead of making a partial stack look like a short one.
- **`kernel_truncated`.** The kernel stack had more than 32 frames, so its root is missing.

## 4. How the binaries get to the server

Regions arrive with every report, but a binary can be megabytes and is the same every time. It
is sent differently: once, on request, in small pieces.

### 4.1 The four steps (`symbols/offer.zig`)

```
 report ──► regions_see: new build ID?  ──► queue (16 at most)
                                               │
 tick ────► pump ─► binary_known(id)? ─yes─► drop, nothing sent
                       │ no
                       ▼
                    binary.open: /proc/<pid>/root/<path>, check the build ID, read the headers
                       │
                       ▼
                    binary_begin(header) → binary_chunk × N → binary_end
                                                 (or binary_abort if it stops early)
```

1. **Offer.** After each report, `regions_see` looks for build IDs not seen in this run, and
   queues those regions. It takes file regions, and `[vdso]` once it has its ID.
2. **Ask.** The server answers `binary_known(build_id)`. If it already has the binary, from
   another process or an earlier run, nothing more happens. This makes "once per build ID" true
   across the whole fleet, not just per run.
3. **Open.** `binary.open` opens the file as the target sees it, and checks that the build ID in
   it is the one the target mapped. If an upgrade replaced the file, the agent sends nothing
   rather than the symbols of another build. It reads only the ELF headers (`elf_file.load`
   with no sections), to find where the four sections are.
4. **Send.** `binary_begin(header)`, then the section bytes as chunks of 256 KiB, then
   `binary_end`. If a hook fails or the run stops in the middle, the server gets
   `binary_abort`, so it never keeps half a binary.

### 4.2 Why it looks like a network stream

The hooks are `begin`, `chunk`, `end`, `abort`, with a question (`known`) before them. That is
the shape of a streaming RPC. In-process today, the server's `Run` gets the calls directly.
With gRPC later, only what the hooks do changes, to sending messages on a stream. The agent's
code stays the same.

### 4.3 What it costs, and its limits

The agent profiles a machine that has its own work to do, so every cost is bounded:

| Limit | Value | Why |
|---|---|---|
| chunk size | 256 KiB | the agent holds one chunk whatever the size of the binary |
| chunks per loop round | 4 | at most 1 MiB per 100 ms tick; the loop keeps draining the kernel's ring buffer |
| transfers at once | 1 | one open file, one buffer |
| build IDs remembered per run | 256 | a hostile target mapping thousands of files cannot grow the agent |
| waiting queue | 16 | new binaries come a few at a time; the rest wait for the next report |
| section names read | 1 MiB | the size comes from the file, which is untrusted |

There is no limit on the size of the application: a 2 GiB binary takes more rounds, not more
memory.

A failure (unreadable file, wrong file, a hook error) is logged, the binary is dropped for the
rest of the run, and profiling goes on. Symbols are worth having, but they must never cost the
profile.

The vDSO is sent straight from the image the agent already holds: no file is opened and no copy
is made.

## 5. How this fits the agent's flow

Ep15 described one sample's journey and one report's journey. The new pieces sit on top of the
loop the agent already had, without changing the kernel side. The kernel program still does
only one thing: walk stacks and count them.

### 5.1 At start

```
profile()
  ├─ PidFd, Session.init
  │    ├─ kernel.read             ← release, build ID, _text           (new: sent in Message)
  │    ├─ regions read            ← the target's mappings + build IDs  (first, while it lives)
  │    ├─ Tables.init             ← copies the vDSO image (Ep13)
  │    ├─ vdso_mark               ← the [vdso] region gets that image's build ID   (new)
  │    ├─ Tables.sync, Collector.init
  ├─ Offer.init(enabled = context has the hooks, the vDSO image)          (new)
  └─ timers armed, loop_run
```

The first regions are read before the unwind tables are built, because a short-lived target may
already be a zombie by the time the tables are done, and a zombie has no maps. So the `[vdso]`
region is marked just after the image exists.

### 5.2 In the loop

```
 tick (≤100 ms)                         report (every interval_ms)
 ──────────────                         ──────────────────────────
 session.tick: drain the ring           session.report
 offer.pump: ≤4 chunks          (new)     ├─ generation advance, regions refresh (+ vdso_mark)
                                          ├─ tables sync, counts drain → Window
                                          └─ Report { regions, kernel, unwind, cpu }
                                        offer.regions_see(report.regions)     (new)
                                        on_report(context, &report)
```

The two jobs share one thread and one loop, and do not get in each other's way:

- **Reports are not delayed by binaries.** `regions_see` only copies a few IDs and paths into a
  queue. The sending happens on ticks, a bounded amount at a time.
- **The kernel ring is still drained on every tick.** A tick sends at most 4 chunks, then goes
  back to waiting, so a big binary never holds up the drain the ring depends on (Ep11).
- **No new kernel work.** Regions were already read for the unwinder, and build IDs were
  already read for the tables' registry. The symbols path reuses them, and opens a file only
  when the server asks.

### 5.3 At the end

`profile` stops the offer before it frees anything. A transfer still in flight gets
`binary_abort`, on a normal stop and on an error alike. Then the session releases what it
loaded into the kernel, as before.

### 5.4 A context without the hooks

`binaries_wanted` is decided at compile time from the context's type. A context without
`binary_known`, such as the CLI or the Ep14 example, gets an `Offer` that is disabled: it
allocates nothing, and no binary code is compiled into its loop. A context with `binary_known`
must have all five hooks with the right signatures, or the build fails and names the hook,
for example:

```
error: profile: `run.Run.binary_abort` is missing
error: profile: `run.Run.binary_abort`: must not fail
```

## 6. On the server side

The server owns the rest, and needs nothing from the target machine:

1. **Find the region** of an address. Regions are sorted and do not overlap, so this is a binary
   search (`server/symbolize/regions.zig`, the first step, already there).
2. **File offset** = `address - region.start + region.offset`, with `address - 1` for every
   return address (all user frames after the first, and the first one too when
   `leaf_is_return`).
3. **Symbol table** of the build ID, built once from the sections the agent sent: a sorted array
   of functions by file offset, searched by binary search.
4. **Merge** equal stacks after naming, because two addresses in the same function become one
   frame.

All of this happens when someone asks for a profile, not when samples arrive. Samples stay small
in the store, and when the symbolizer gets better (DWARF line numbers, Go's `.gopclntab` names,
kernel symbols), old profiles get the better names without being taken again.

## 7. What is not done yet

- **Binaries without a build ID** are not offered. A fallback identity computed by the agent
  (for example a hash of the headers and size) would cover many Zig and Go binaries.
- **Kernel symbols** are not sent. The identity is, so the server can find them itself.
- **Go names from `.gopclntab`** and **DWARF line tables** are not sent yet. Stripped Go binaries
  have no `.symtab`, so their frames stay unnamed until then.
- **No retry.** A binary that failed once is not offered again in the same run.

## 8. Summary

- An address needs three things to become a name: its file (region + build ID), its place in the
  file (file offset), and that file's symbols (the binary stream).
- Regions and the kernel identity travel with every report. Binaries travel once per build ID,
  only when the server asks, in bounded chunks.
- The key is `(build ID, file offset)`: independent of ASLR, of paths and of machines.
- The `[vdso]` gets the build ID of the agent's own image, the leaf flag fixes syscall frames,
  and every cost has a limit.
- It fits into the existing loop: regions after each report, chunks on each tick, an abort at
  the end. The kernel side is unchanged.
