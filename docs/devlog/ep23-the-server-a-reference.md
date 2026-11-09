---
date: 2026-11-09
---

# Ep23: The Server, a Reference

Ep20 told how the server was split into layers. This episode is the server as it is today, the
same way Ep22 is for the agent: to come back to when something has to be added or changed.

1. [What the server is, and how to use it](#1-what-the-server-is-and-how-to-use-it)
2. [The files](#2-the-files)
3. [The layers and who imports whom](#3-the-layers-and-who-imports-whom)
4. [Each layer](#4-each-layer)
5. [The parent: Server and Feed](#5-the-parent-server-and-feed)
6. [The local client: Controller](#6-the-local-client-controller)
7. [A profile from start to end](#7-a-profile-from-start-to-end)
8. [Threads and locks](#8-threads-and-locks)
9. [Extending the server](#9-extending-the-server)
10. [Tests](#10-tests)

## 1. What the server is, and how to use it

The agent sends raw addresses and the binaries they are in. The server keeps the reports, builds
the binaries' symbol tables, and answers with **profiles**: the stacks with their functions
named and equal stacks merged. It also keeps the newest frame of the processes watch.

It exports two things:

| | What it does |
|---|---|
| `Server` | Takes the agents' events and answers queries. Knows nothing of where the events come from: this process, or a network. |
| `Controller` | The local client: runs the agent on threads of this process and feeds the server. What `nusku prof` and `nusku ps` use today. |

**Feeding it** is one `Feed` per agent run, and one call per event:

```zig
var server: Server = undefined;
try server.init(gpa, .{});                       // starts the symbols' builder thread
defer server.deinit();

var feed = try server.feed(pid);                 // once per run
defer feed.close();
while (try run.next()) |event| switch (try feed.take(event)) {
    .none => {},
    .wanted => run.binary_want(true),            // the answer to an offer
    .unwanted => run.binary_want(false),
};

while (try watch.next()) |event| try server.watch_take(event);
```

**Asking it** is two queries, each copying into the caller's arena, so the result is the
caller's to keep:

```zig
const profile = try server.profile(arena, .{ .target = feed.target }, .all_built);
const latest = try server.processes(arena);      // .frames so far, .frame the newest (or null)
```

| Function | What it does |
|---|---|
| `init(gpa, options)` | Reserves the windows, starts the builder thread. The server must stay at its address. |
| `deinit()` | Stops the builder after the build in progress, frees everything. |
| `feed(pid)` | Registers a process for one run: its windows are queried under `feed.target`. |
| `watch_take(event)` | Keeps a watch frame as the newest. |
| `profile(arena, query, names)` | The query's windows, named and merged. `.as_they_are` names with the tables there now; `.all_built` first waits for every binary received to get its table. |
| `processes(arena)` | The newest watch frame, and how many came. |
| `Feed.take(event)` | One run event, and what to answer the agent. |
| `Feed.close()` | The run is over: its windows stay for queries, a binary half sent is dropped. |

A `Query` is a target and a time range (`from_unix_ns`, `to_unix_ns`; all of it by default).

**Everything that comes in is a `shared/protocol` type**: `RunEvent`, `WatchEvent`, `Message`,
`binary.*`, `ProcessFrame`. What goes out (`Profile`, `SymbolStack`, `Frame`, `Latest`) is the
server's own, exported from `root.zig`. A module that needs a protocol type imports it from
`shared`, never through the server.

## 2. The files

```
server/
  root.zig       the module: Server, Feed, Controller and the types they take and give
  log.zig        the server's log scope
  build.zig      the module, its tests

  os/         os.zig         toolbox: Lock, Condition (lock.zig)
  windows/    windows.zig    Windows; store (the targets), window_ring (one target's windows)
  symbols/    symbols.zig    Symbols and Receiver; upload, builder, symbol_table, binaries,
                             id_set
  processes/  processes.zig  Processes: the newest watch frame
  naming/     naming.zig     profile(); regions, normalize, resolve, lookup, merge
  server/     server.zig     Server and Feed: the parent of the layers above
  control/    control.zig    Controller; job (one agent run or watch on a thread)

  testing/       test-only: burn.zig, symbols.zig (fixtures), e2e/profile_named.zig
```

As in the agent, the root holds only the module's door, and every layer is a folder with its
facade named like it.

## 3. The layers and who imports whom

```
   root.zig ─────────── exports Server, Feed, Controller, and their types
                │
   rank 4    control ─────────────────── imports the agent (the only layer that does)
                │
   rank 3    server  (Server, Feed: the parent of the layers below)
             │   │   ╲________________
   rank 2    │  naming                 ╲
             │  ╱    ╲                  ╲
   rank 1  windows  symbols          processes     (beside each other: never import)
                ╲      │               ╱
   rank 0        ╲──── os ────────────╱
```

| Layer | Rank | Imports | Is |
|---|---|---|---|
| `os` | 0 | nothing of the server | toolbox |
| `windows` | 1 | os | `Windows` |
| `symbols` | 1 | os | `Symbols`, `Receiver` |
| `processes` | 1 | os | `Processes` |
| `naming` | 2 | windows, symbols | `profile()` |
| `server` | 3 | windows, symbols, processes, naming | `Server`, `Feed` |
| `control` | 4 | server, the agent | `Controller` |

The rules are the agent's (Ep21 §2): a file imports its own layer and the facades below it, never
one beside it. `windows`, `symbols` and `processes` each keep one thing and know nothing of the
others; `naming` is the first to see two of them, and only reads.

**The server never imports the agent** except in `control`. Everything else works on
`shared/protocol` types, so the same server takes events from a network the day there is one.

## 4. Each layer

### os: what the threads share

**Why:** every layer with state is called from several threads, and needs the same lock.

| Tool | What it is |
|---|---|
| `Lock` | a mutex |
| `Condition` | waited on under a `Lock`: the builder sleeps on one, `wait()` too |

### windows: what the agents reported

**Why:** a profile is made from the windows of a time range, so they must be kept, per target,
within a fixed budget of memory.

```zig
pub const Windows = struct {
    pub fn init(windows: *Windows, gpa, options) !void   // reserves every window up front
    pub fn deinit(windows, gpa) void
    pub fn add(windows, gpa, pid) !TargetId     // once per run
    pub fn finish(windows, target) !void        // no more windows will come
    pub fn put(windows, target, message) !void  // the newest window; never allocates
    pub fn copy(windows, arena, query) !Copied  // the query's windows, oldest first
};
```

| Option | Default | Means |
|---|---|---|
| `targets_max` | 16 | processes kept at once; a new one replaces the oldest finished |
| `windows_per_target_max` | 120 | the oldest window goes when a new one comes |
| `window_bytes_max` | 128 KiB | a window bigger than this is rejected and counted (`windows_rejected`) |

Each target's windows are a ring of fixed slots (`window_ring.zig`): `put` copies a message into
its slot's bytes, so a busy agent never makes the server allocate. A target outlives its run,
so a query after the end still finds it.

### symbols: the binaries' symbol tables

**Why:** naming an address needs the function table of its binary. The binaries arrive from the
agents in chunks, untrusted, and a big one takes long to parse: that must never hold up a run.

```zig
pub const Symbols = struct {
    pub fn init(symbols: *Symbols, gpa, options) !void   // starts the builder thread
    pub fn deinit(symbols) void
    pub fn used(symbols, regions) void                   // these tables are needed: keep them
    pub fn name(symbols, arena, build_id, offset) !?[]const u8
    pub fn wait(symbols) void                            // until every build has ended
    pub fn stats(symbols) Stats
};

pub const Receiver = struct {                            // one per agent run
    pub fn init(symbols) Receiver
    pub fn deinit(receiver) void                         // drops a binary still arriving
    pub fn take(receiver, event: RunEvent) Answer        // offer, begin, chunk, end, abort
};
```

The path of a binary:

```
offer    unwanted if its table is here, being built, being sent by another run, or refused
begin    claimed (no other run may send it now), its bytes reserved from the upload budget
chunks   checked against the header: anything that does not fit ends the upload
end      queued for the builder thread; the run goes on at once
build    symbol_table.zig: the functions sorted by file offset, names in one blob
keep     binaries.zig: within binaries_max and binaries_bytes_max; least recently used go
```

A failure drops that binary only, never the run: the agent is told `unwanted`, and its frames
stay unnamed. A table too big to keep is remembered as refused, so it is not sent again. Tables
are keyed by **build ID and file offset**, which are the same in every process and every run
whatever ASLR did, so one table serves every target that maps that binary. The kernel's symbols
arrive the same way, under the kernel's identity (build ID plus `_text`).

| Option | Default |
|---|---|
| `binaries_max` | 1024 tables |
| `binaries_bytes_max` | 256 MiB, all tables together |
| `uploads_bytes_max` | 1 GiB, all uploads together until their table is built |
| `upload_bytes_max` | 512 MiB, one binary |

### processes: the newest watch frame

**Why:** `nusku ps` asks for "now", not for history, so one frame is kept.

```zig
pub const Processes = struct {
    pub fn init(gpa) Processes
    pub fn deinit(processes) void
    pub fn put(processes, frame) !void              // copies it: the agent reuses its own
    pub fn latest(processes, arena) !Latest         // .frames so far, .frame the newest
};
```

The copy is deep, field by field for the slices and whole for the rest, so a new number field in
`ProcessInfo` or `Machine` is kept without a line here.

### naming: windows into a profile

**Why:** the only place that needs both the windows and the symbols, and only to read them.
A pure function: no state, no lock of its own.

```zig
pub fn profile(arena, copied: windows.Copied, symbols: *Symbols) !Profile

pub const Profile = struct {
    sample_hz: u32,
    samples: u64,
    samples_lost: u64,
    windows_rejected: u64,
    stacks: []const SymbolStack,   // most samples first
};
pub const SymbolStack = struct { samples: u64, frames: []const Frame, complete: bool };
pub const Frame = struct {         // innermost first, kernel frames before user frames
    address: u64,
    kernel: bool,
    function: ?[]const u8 = null,  // null: not named
    file: ?[]const u8 = null,
    line: ?u32 = null,
    module: ?[]const u8 = null,    // the binary's path
};
```

For each window: `regions.zig` finds the region of each user address (a binary search),
`normalize.zig` turns it into an offset in that region's file, `lookup.zig` names (build ID,
offset) through a cache in front of the tables, `resolve.zig` does it for every stack. Kernel
frames are named against the kernel's table, from their distance to `_text`. Then `merge.zig`
merges the stacks with the same call path, from any window and any instruction of the same
functions. An address with no table keeps its address and module: it loses its name, nothing
worse.

## 5. The parent: Server and Feed

`server/server.zig` is the only code that sees every layer. It owns nothing but the order:

| Call | What it does with the layers |
|---|---|
| `feed(pid)` | `windows.add` → a `Feed` with that target and a `symbols.Receiver` |
| `Feed.take(.report)` | `windows.put` (a window too big is counted, the run goes on), then `symbols.used(regions)` |
| `Feed.take(binary event)` | `receiver.take` → the answer |
| `Feed.close()` | `receiver.deinit` (drops a half-sent binary), `windows.finish` |
| `watch_take(.frame)` | `processes.put` |
| `profile(...)` | `symbols.wait` if `.all_built`, `windows.copy`, `naming.profile` |
| `processes(arena)` | `processes.latest` |

`Feed.take` fails only when the store fails; a binary that fails is answered `unwanted`, and the
run goes on.

## 6. The local client: Controller

**Why:** `nusku` runs the agent and the server in one process. Someone has to pull the agent's
events and push them into the server, on threads, and stop them on Ctrl-C. That is `control`,
the only layer that imports the agent.

```zig
pub const Controller = struct {
    pub fn init(controller: *Controller, gpa, server: *Server, options) !void
    pub fn deinit(controller) void                   // stops what is still going
    pub fn start(controller, spec: Spec) !Started    // .job, and .target for a profile
    pub fn stop(controller, job) !Done               // ask it to stop, wait for it
    pub fn wait(controller, job) !Done               // wait for it to end by itself
    pub fn running(controller, job) bool
    pub fn interrupt(controller) void                // stop every job; safe from a signal
};

pub const Spec = union(enum) {
    profile: struct { pid, metrics = .cpu, interval_ms = 1000, duration_s = 0 },
    processes: struct { interval_ms = 1000, duration_s = 0 },
};
pub const Done = union(enum) { profile: RunStop, processes: WatchStop };
```

A **job** (`control/job.zig`) is one agent `Run` with its `Feed`, or one `Watch`, on a thread
of its own. Its loop is the whole local transport:

```zig
while (try run.next()) |event| switch (try feed.take(event)) {
    .none => {},
    .wanted => run.binary_want(true),
    .unwanted => run.binary_want(false),
};
```

`start` returns once the agent is set up (about a second for a profile), so "no permission" or
"the process is gone" comes out of `start`, not later. One watch at a time; up to `jobs_max`
(16) jobs. The CLI polls `running` and queries the server meanwhile to show a live view.

## 7. A profile from start to end

```
controller.start(.profile)            agent.Run.init → server.feed(pid) → the job's thread
job thread, until the run stops:
  .binary_offer   → receiver: known? → .unwanted / .wanted → run.binary_want
  .binary_begin   → claim, reserve bytes
  .binary_chunk   → upload, checked
  .binary_end     → queued → builder thread → symbol_table → binaries
  .report         → windows.put; symbols.used(regions)
  .stopped        → the job ends: Done.profile(reason)
meanwhile, the CLI:
  server.profile(arena, .{ .target }, .as_they_are)   the live view, every second
at the end:
  controller.wait(job) → feed.close
  server.profile(arena, .{ .target }, .all_built)     waits for the last tables, then names
```

## 8. Threads and locks

| Thread | Does |
|---|---|
| the caller's (CLI) | `start`, `stop`, `wait`, queries |
| one per job | `run.next` → `feed.take`, or `watch.next` → `watch_take` |
| the builder (one, in `symbols`) | builds tables from uploads that ended |

`windows`, `symbols` and `processes` each have their own lock, held only for bounded work: a
copy, a lookup, a put. A query copies under each lock and computes outside, so a profile being
named never holds up an agent's report. `naming` has no lock: it works on copies and asks
`symbols.name` one pair at a time, through its cache. `Server` and `Feed` have no lock: they
only call the layers. A `Feed` is used by one thread, its job's.

## 9. Extending the server

Each change lands in one layer, plus `server.zig` when a new event or query has to reach it.
If a layer seems to need one beside it, the shared part is a layer below both, or the work
belongs in `naming` or `server`.

### A new metric (off-CPU, memory, …)

1. `shared/protocol`: what a message carries for it (the agent side is Ep22 §7).
2. `windows`: nothing, if it is part of `Message`; the window is copied whole.
3. `naming`: nothing, if its stacks are named like the CPU's. If not, its own step in
   `naming/`, and a field in `Profile`.
4. A query on `Server` if it is asked for apart from the CPU profile.

### A new query

A function on `Server`: copy what it needs under each layer's lock, compute outside, return in
the caller's arena. If the computation is big or reads two layers, it is a new file in `naming/`
or a new layer at rank 2, never inside `windows` or `symbols`.

### More to keep (history of the watch, …)

In the layer that keeps that thing: a ring of frames in `processes/` instead of one, behind the
same `put` and a new query. Fixed memory, reserved up front, like `windows`.

### Names with file and line

`Frame` already has `file` and `line`. Debug info would be another kind of section sent by the
agent's `symbols`, another table in `symbols/`, and `lookup` filling them. `naming`'s shape does
not change.

### A new transport (gRPC, …)

Nothing in the layers changes. A network server is a loop that reads an event from the
connection, calls `Feed.take` (or `watch_take`), and writes back the `Answer`; and endpoints for
`profile` and `processes`. It replaces what `control/job.zig` does in-process: the job's loop
runs in the agent's process instead, with the network between `next()` and `take()`. The CLI
gets `client/remote.zig` next to `local.zig`, with the same three functions.

### A new layer

A folder `name/` with `name/name.zig`, its rank one above what it imports, nothing beside it,
named for what it gives, and its line in `root.zig`'s list and test block.

## 10. Tests

| Where | What |
|---|---|
| in each file, after `// ---- tests` | unit tests; layers tested with fixtures, no agent needed |
| `server/testing/symbols.zig` | fixtures: a binary and a symbol table of one function, for every layer that names addresses |
| `server/testing/burn.zig` | keeps the CPU busy, so a profile of the test process has something in it |
| `server/testing/e2e/profile_named.zig` | the controller profiles the test process (root): `burn` and its caller must be named |
| `testing/` (repo root) | `make check`: the whole `nusku` against apps with known profiles |

`server/server.zig`'s own tests feed it messages by hand and check the profile: the range, the
names, a window too big. `control.zig`'s run real jobs (root for a profile; the watch needs
none). Test-only code lives under `testing/`, never in the server's files.
