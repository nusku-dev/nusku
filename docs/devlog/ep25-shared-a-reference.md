---
date: 2026-11-09
---

# Ep25: Shared, a Reference

The fourth reference, after the agent (Ep22), the server (Ep23) and the CLI (Ep24). `shared/` is
what more than one of them needs, so none of them owns it: **the protocol** between the agent and
the server, and **reading files**, ELF files among them.

1. [What shared is, and what it is not](#1-what-shared-is-and-what-it-is-not)
2. [The files](#2-the-files)
3. [Who uses what](#3-who-uses-what)
4. [The protocol](#4-the-protocol)
5. [Reading files: File and Directory](#5-reading-files-file-and-directory)
6. [ELF: elf.zig](#6-elf-elfzig)
7. [Extending shared](#7-extending-shared)
8. [Tests](#8-tests)

## 1. What shared is, and what it is not

**It is** a library of small parts with no state: types, and functions on bytes and files.
Every module imports it the same way, by name:

```zig
const protocol = @import("shared").protocol;
const File = @import("shared").File;
```

**It is not** a module made of layers. Nothing in it calls up into the agent, the server or the
CLI, and nothing in it runs a thread or keeps anything between calls. That is why it has no
facade struct with `init` and `next`: each part is used on its own.

Three rules keep it that way:

- **It imports nothing of the repository's other modules.** Only `std`, and its own files.
- **Something goes here only when two modules need it.** Code only the agent uses stays in the
  agent, even if it looks general. `Directory` moved here when the layer checker needed it, and
  stayed when the checker went, because the agent uses it too; `elf.zig` is here because the
  agent reads ELF files to send them and the server reads them to build symbol tables.
- **A shared type is imported from `shared`, by every module, the CLI too.** No module
  re-exports one: `server.ProcessFrame` would make the CLI depend on the server for a type the
  server does not own.

## 2. The files

```
shared/
  root.zig        what the module exports: protocol, elf, directory, File, FileError
  protocol/
    protocol.zig  the events, the answers, the reasons, and the types below
    message.zig   Message (Stack, Kernel), Region: one report of a run
    binary.zig    Offer, Header, Chunk, Section: a binary sent for its symbols
    kernel.zig    how kernel frames are named: path, id, segment
    processes.zig ProcessInfo, Frame, Machine, MachineCpu: one look at the machine
  file.zig        File: read-only, positional reads
  directory.zig   Directory: a directory's names
  elf.zig         sections, segments and the load bias of an ELF file
```

As everywhere, a folder's facade is the file named like it: `protocol/protocol.zig`.

## 3. Who uses what

| Part | Agent | Server | CLI |
|---|---|---|---|
| `protocol` | fills it: every event it gives | reads it: every event it takes | shows it: `ProcessFrame`, `Metric`, `RunStop` |
| `File` | `/proc`, binaries, build IDs, `kallsyms` | | |
| `directory` | `/proc`, through `os.directory` | | |
| `elf` | sections and segments: its `elf/` layer, unwind tables, the vDSO, the binaries it sends | the segments of a binary it was sent, building its symbol table | |

## 4. The protocol

**Why:** the agent and the server are two programs, even when they run in one process. What
crosses between them is a contract: the agent fills it, the server reads it, and neither may
change it alone. With a network between them one day, the contract stays the same; only how it
is carried changes.

### The events

```zig
pub const RunEvent = union(enum) {         // what a profiling run gives, in order
    report: *const Message,                // a window of samples, every interval
    binary_offer: binary.Offer,            // answered with `Answer`
    binary_begin: *const binary.Header,
    binary_chunk: binary.Chunk,
    binary_end,
    binary_abort,                          // the binary begun will not end
    stopped: RunStop,                      // the last event
};

pub const Answer = enum { none, wanted, unwanted };   // the server's reply to each event

pub const WatchEvent = union(enum) {       // what a processes watch gives
    frame: *const ProcessFrame,            // every interval; the first has no CPU
    stopped: WatchStop,
};

pub const Metric = enum { cpu, offcpu, mem, io, net, locks, sched };  // only cpu so far
pub const RunStop = enum { duration, target_exited, cancelled };
pub const WatchStop = enum { duration, cancelled };
```

**Events are borrowed.** A pointer or a slice in an event points into the sender's memory and
is valid until its next event. The receiver copies what it keeps; `Message.clone` and
`Header.clone` do it.

**Answers make it a conversation.** Every `RunEvent` gets an `Answer`. It matters only for an
offer (`wanted` or `unwanted`) and during a transfer (`unwanted` stops it); everything else is
answered `none`.

### Message: one report of a run

```zig
pub const Message = struct {
    start_unix_ns: u64,      // when the window began (wall clock)
    duration_ns: u64,        // how long it lasted (monotonic)
    pid: u32,
    sample_hz: u32,          // samples / sample_hz = CPU seconds
    samples: u64,
    samples_lost: u64,       // every reason together
    regions: []const Region, // what the addresses are resolved against
    stacks: []const Stack,
    kernel: Kernel = .{},    // release, build ID, `_text`: what names kernel frames
};

pub const Stack = struct {
    samples: u64,
    user: []const u64,       // raw addresses, innermost first
    kernel: []const u64,
    complete: bool,          // the walk reached the outermost frame
    leaf_is_return: bool = false,
    kernel_truncated: bool = false,
};

pub const Region = struct {  // one executable mapping
    start: u64, end: u64, offset: u64, inode: u64,
    path: []const u8,        // "[vdso]" for the vDSO
    build_id: ?[]const u8,   // what the server names it by
};
```

**Addresses travel raw.** The agent never names a function; it sends the address and the region
it is in. The server places the address in the region's file (`offset + address - start`) and
names it with that binary's table, keyed by **build ID**. The same binary is the same table in
every process and every run, whatever ASLR did.

The CPU used over a window is in the message too: `(samples + samples_lost) / sample_hz /
(duration_ns / 1e9)` cores.

### binary: a binary sent for its symbols

```zig
pub const Offer = struct { build_id, path };       // "I have this one: do you want it?"
pub const Header = struct {
    build_id, path,                                // the path is for display only, never opened
    segments: []const Segment,                     // how a file offset becomes an address
    sizes: EnumArray(Section, u64),                // 0 for a section the file lacks
};
pub const Chunk = struct { section: Section, offset: u64, bytes: []const u8 };
pub const Section = enum { symtab, strtab, dynsym, dynstr };
```

Only the sections that name things are sent, not the whole file. The order is fixed: offer,
begin (the header), chunks in order, end; or abort. The server checks every chunk against the
header: everything from an agent is untrusted.

### kernel: naming kernel frames

The kernel's symbols are sent like a binary, under `path = "[kernel]"`, each symbol at its
distance from `_text`. Its identity, `id(buffer, build_id, text_address)`, is the kernel's build
ID followed by `_text`: good for one boot, since `_text` moves with KASLR. `segment` makes every
offset its own address, so the server's usual lookup works unchanged.

### processes: one look at the machine

```zig
pub const Frame = struct {
    unix_ns: u64,
    interval_ns: u64,               // what the CPU is measured over; 0 on the first look
    processes: []const ProcessInfo,
    machine: Machine = .{},
};
pub const ProcessInfo = struct {
    pid, name, user, command,       // command empty for a kernel thread
    threads: u32,
    cpu_percent: ?f32,              // of one CPU; null on the first look
    memory_bytes: u64,              // resident
    started_unix_ns: u64,
};
pub const Machine = struct { cpus: u32 = 0, cpu: ?MachineCpu = null };
pub const MachineCpu = struct {     // shares of every CPU together: 100 = all busy
    busy_percent, user_percent, system_percent, iowait_percent, irq_percent, steal_percent: f32,
};
```

## 5. Reading files: File and Directory

**Why:** the agent reads hundreds of small files every second (`/proc/<pid>/…`) and large ones
in parts (binaries, `kallsyms`). It needs reads that never allocate and never depend on a file
position.

```zig
pub const File = struct {
    pub fn open(path: [:0]const u8) OpenError!File   // read-only
    pub fn deinit(file) void
    pub fn read_at(file, buffer, offset) ReadError!usize  // fills the buffer or reaches the end
    pub fn read(file, buffer) ReadError!usize        // one read, for files with no size (/proc)
    pub fn size_bytes(file) ReadError!u64
};

pub const Directory = struct {
    pub fn open(path: [:0]const u8) !Directory
    pub fn deinit(directory) void
    pub fn next(directory) !?[]const u8              // includes "." and "..": the caller filters
};
```

`read_at` goes through `pread`, retries an interrupted read a few times, and returns less than
the buffer only at the end of the file: a caller that gets a full buffer knows there may be
more. A process that ended while its `/proc` files were read gives `ProcessNotFound`, which the
callers skip.

## 6. ELF: elf.zig

**Why:** both sides read ELF files, and both read them from untrusted bytes: the agent from
files on disk, the server from what an agent sent. Every offset is checked before it is read.

```zig
pub fn find(file: []const u8, wanted: []const u8) Error!?Section   // a section by name
pub fn bytes_of(file, section) ?[]const u8                         // its bytes, if in the file
pub fn segment_mapped(file, region_offset) Error!?Segment          // the segment a mapping is
pub fn segments_executable(file, out: []Segment) Error!usize       // all executable segments
pub fn load_bias(file, region_start, region_offset) Error!?u64     // address in memory − in file
```

`Error` is `NotElf`, `Truncated` or `Unsupported` (only 64-bit little-endian). Every function
works on bytes already read, so it is the caller's choice how much of the file to read.

The agent also has its own `elf/` layer: reading a file's headers and only the asked-for
sections from disk, and `.eh_frame`. That stays in the agent, because only the agent does it.

## 7. Extending shared

### A new field in a protocol type

Give it a default (`= 0`, `= null`, `= .{}`) when it can have one: every place that builds the
type keeps compiling, and the server's copies (`Message.clone`, the watch frame's copy) copy a
number field without a new line. A slice field needs a line in the clone or copy.

### A new event or a new type

A new type goes in `protocol/` and is exported from `protocol/protocol.zig`. A new event is a
new field of `RunEvent` or `WatchEvent`: the compiler then points at every `switch` that must
handle it, in the agent, the server and the CLI.

### A new metric

`Metric` already names `offcpu`, `mem`, `io`, `net`, `locks` and `sched`, so a caller can ask for
them today and get `MetricNotImplemented`. A new one needs what its windows carry: fields in
`Message` (or its own type, if it is not stacks), and the steps of Ep22 §7 and Ep23 §9.

### Carrying the protocol over a network (gRPC, …)

The types are plain Zig structs with slices, made for one address space. A transport adds an
encoding next to them (in `protocol/`, since both ends need it), turning each event into bytes
and back. The events and their order do not change, so neither do the agent's `next()` or the
server's `take()`.

### Something new in shared

Only when a second module needs it. It imports nothing of the other modules, keeps no state,
and treats what it reads as untrusted. Export it from `root.zig` and add it to the test block.

## 8. Tests

| Where | What |
|---|---|
| `protocol/message.zig`, `binary.zig` | the clones are deep and complete |
| `protocol/kernel.zig` | the kernel's identity needs both its parts |
| `elf.zig` | sections, segments and the load bias, and files that are not ELF, truncated, or without section headers |
| `directory.zig` | reading a real directory |
| `file.zig`, `protocol/processes.zig` | none of their own: `File` is used by every `/proc` reader of the agent, and tested through them |

`zig build test` runs them with every other module: shared has its own test step, so its tests
do not depend on another module to import it. Nothing here needs root.
