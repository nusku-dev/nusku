---
date: 2026-11-08
---

# Ep20: The Server and the CLI, in Layers

[Ep19](ep19-layers-a-pull-api-and-one-protocol.md) rebuilt the agent as layers, each with one
facade, and gave it a pull API. This episode does the same to the server and to the CLI, so the
whole project reads one way:

- The server takes the agents' **events** and answers them, the same way however the events
  reach it: a `Feed` per agent run, `take(event)` in, an `Answer` out.
- Its one big struct, with one lock and 19 public functions, became five layers with their own
  locks and a few functions each.
- The controller, the local client, runs **jobs**: a profile or a processes watch, both started,
  stopped and waited for the same way.
- The CLI got the same shape: term, client, view, cmd.
- The rule of the layers is one checker in `shared/`, run on all three.

## 1. What was wrong with the server

`server/server.zig` was 761 lines. One `Server` held the windows, the symbol tables, the upload
budget and claims, the build queue and its thread, and the processes frame, all under one lock.
Its public functions:

```
init  deinit  stats  target_add  target_finish  target_remove  ingest  window_dropped
processes_ingest  processes  processes_frames  binary_known  upload_start  upload_abort
upload_end  binary_received  binary_put  builds_wait  profile
```

To feed it, a caller had to know the order of a conversation spread over seven of these:
`target_add` once, `ingest` each report, `binary_known` for an offer, `upload_start` for a
header (which hands back a ticket to keep), then `upload_end` or `upload_abort`, and
`target_finish` at the end. That knowledge lived in `control/run.zig`, the only caller. A second
transport, a network one, would have had to learn it all again.

And one lock for everything meant a profile query, which names thousands of frames, took turns
with the agent's reports and uploads.

## 2. The server now

```
   control     Controller: start · stop · wait · running · interrupt       ─┐ the local client
   ─────────────────────────────────────────────────────────────────────    │
   server      Server: feed · watch_take · profile · processes               │
               Feed:   take(event) → Answer · close                         │
   ─────────────────────────────────────────────────────────────────────    │
   naming      profile(arena, windows, symbols)                             │
   ─────────────────────────────────────────────────────────────────────    │
   windows     Windows            symbols     Symbols        processes      │
   add · finish · put · copy      used · name · wait · stats  put · latest  │
                                  Receiver: take(event) → Answer            │
   ─────────────────────────────────────────────────────────────────────    │
   os          Lock, Condition                                              ┘
```

| Layer | Rank | Responsible for |
|---|---|---|
| `os` | 0 | The lock and the condition the threads share. |
| `windows` | 1 | Each target's ring of windows: what the agents reported. A target outlives its run. |
| `symbols` | 1 | The binaries' symbol tables: receiving them, building them on a thread of its own, naming an offset. |
| `processes` | 1 | The newest frame of the processes watch. |
| `naming` | 2 | A profile: windows named with the symbols, equal call paths merged. |
| `server` | 3 | The layers together: taking events, answering queries. |
| `control` | 4 | The local client: the agent on threads of this process, feeding the server. |

`windows`, `symbols` and `processes` do not know each other. Each has its **own lock**, held
for bounded work: a query copies its windows under the windows' lock, then names them asking the
symbols one pair at a time, so an agent's report never waits for a query.

### 2.1 windows

```zig
pub const Windows = struct {
    pub fn init(windows: *Windows, gpa, options: Options) !void
    pub fn deinit(windows: *Windows, gpa) void
    pub fn add(windows: *Windows, gpa, pid: u32) !TargetId
    pub fn finish(windows: *Windows, target: TargetId) !void
    pub fn put(windows: *Windows, target: TargetId, message: *const Message) !void
    pub fn copy(windows: *Windows, arena, query: Query) !Copied
};
```

| Function | What it does |
|---|---|
| `add` | Registers a process and allocates its ring, once per run. When full, the oldest *finished* target makes room; a running one never does. |
| `finish` | No more windows will come; they stay for queries until the room is needed. |
| `put` | Copies a message into the ring's next fixed slot: no allocation per report. Too big for a slot: `WindowTooLarge`, counted with the target, logged once. |
| `copy` | The windows overlapping the query's time range, oldest first, copied into the caller's arena, with how many the target lost. |

A `Query` is `{ target, from_unix_ns = 0, to_unix_ns = max }`: the defaults ask for everything.

### 2.2 symbols

```zig
pub const Symbols = struct {
    pub fn init(symbols: *Symbols, gpa, options: Options) !void   // starts the builder thread
    pub fn deinit(symbols: *Symbols) void
    pub fn used(symbols: *Symbols, regions: []const Region) void
    pub fn name(symbols: *Symbols, arena, build_id, offset) !?[]const u8
    pub fn wait(symbols: *Symbols) void
    pub fn stats(symbols: *Symbols) Stats
};

pub const Receiver = struct {
    pub fn init(symbols: *Symbols) Receiver
    pub fn deinit(receiver: *Receiver) void
    pub fn take(receiver: *Receiver, event: protocol.RunEvent) protocol.Answer
};
```

| Function | What it does |
|---|---|
| `used` | The tables a new window needs count as used, so eviction takes those nobody needs. |
| `name` | The function at an offset of a binary, or null. |
| `wait` | Until every binary received has its table, or failed to get one. |
| `stats` | Tables, bytes, builds pending and failed, upload bytes held. |
| `Receiver.take` | One binary event of a run: an offer is answered `wanted` unless the table is here, queued, being built, claimed by another run, or refused before. A header claims the build ID and reserves its bytes of the shared budget. Chunks fill the upload, checked against the header. The end queues it for the builder: the run never waits for a table. Anything that fails drops that binary and answers `unwanted`, never the run. |

The conversation that used to be spread over seven server functions and a ticket is one
`take`, and the ticket is the receiver's own business.

### 2.3 processes and naming

`Processes` keeps a copy of the newest frame: `put(frame)` and `latest(arena)`, which gives the
frame and how many came so far, so a client can wait for the next one without a second call.

`naming` has no state, so it is one function:

```zig
pub fn profile(arena, copied: windows.Copied, symbols: *Symbols) !Profile
```

It places each address in its region's file, names it through a small cache in front of
`Symbols.name` (the same return addresses recur in almost every stack), and merges equal call
paths. A frame whose table is missing keeps its address and its module.

### 2.4 server: Server and Feed

```zig
pub const Server = struct {
    pub fn init(server: *Server, gpa, options: Options) !void
    pub fn deinit(server: *Server) void
    pub fn feed(server: *Server, pid: u32) !Feed                       // in
    pub fn watch_take(server: *Server, event: protocol.WatchEvent) !void // in
    pub fn profile(server: *Server, arena, query: Query, names: Names) !Profile  // out
    pub fn processes(server: *Server, arena) !Latest                   // out
};

pub const Feed = struct {
    target: TargetId,
    pub fn take(feed: *Feed, event: protocol.RunEvent) !protocol.Answer
    pub fn close(feed: *Feed) void
};
```

Two functions in, two out. A feed is one agent run:

```zig
var feed = try server.feed(pid);
defer feed.close();
while (try run.next()) |event| switch (try feed.take(event)) {
    .none => {},
    .wanted => run.binary_want(true),
    .unwanted => run.binary_want(false),
};
const profile = try server.profile(arena, .{ .target = feed.target }, .all_built);
```

`take` puts a report in the windows (a window too big is counted, and the run goes on) and
marks its tables used; it hands binary events to the feed's receiver. Only the store failing
returns an error and stops the run. `Names.all_built` waits for the tables still being built:
the CLI's final report uses it, the live view uses `.as_they_are`.

### 2.5 Why events, and an answer

For this, `RunEvent`, `WatchEvent`, `Answer` and `binary.Offer` moved from the agent into
`shared/protocol`. The agent's `Run.next()` gives a `protocol.RunEvent`; the server's
`Feed.take` takes one and gives back a `protocol.Answer`. Neither knows how the other is
reached.

Today they meet in one process: `control/job.zig` is that loop on a thread. Over a network, the
same loop splits in two: the agent's process sends each event and applies each answer; the
server's receiver calls `feed.take`. Nothing in `windows`, `symbols` or `naming` changes, and the
agent does not change at all.

### 2.6 control: jobs

The controller had ten functions, a set for runs and a set for the watch. Now there is one kind
of thing to run:

```zig
pub const Spec = union(enum) {
    profile: struct { pid: u32, metrics = .initOne(.cpu), interval_ms = 1000, duration_s = 0 },
    processes: struct { interval_ms = 1000, duration_s = 0 },
};

pub const Controller = struct {
    pub fn init(controller: *Controller, gpa, server: *Server, options: Options) !void
    pub fn deinit(controller: *Controller) void
    pub fn start(controller: *Controller, spec: Spec) !Started   // { job, target: ?TargetId }
    pub fn stop(controller: *Controller, job: JobId) !Done        // stop, then wait
    pub fn wait(controller: *Controller, job: JobId) !Done        // until it ends by itself
    pub fn running(controller: *Controller, job: JobId) bool
    pub fn interrupt(controller: *const Controller) void          // every job; signal-safe
};

pub const Done = union(enum) { profile: RunStop, processes: WatchStop };
```

| Function | What it does |
|---|---|
| `start` | A profile waits for the agent's setup (about a second), so no permission or a gone process comes out here; then its feed opens. A watch starts at once; a second one is refused, since two would take turns writing the same frame. Each job gets a thread. |
| `stop` / `wait` | Join the job's thread, close its feed, free the agent's run or watch, and say why it ended. |
| `running` | False once `wait` would return at once: what a client polls. |
| `interrupt` | Stops every job with one eventfd write each: what the CLI's Ctrl-C handler calls. |

A job's thread, for a profile, is the loop of section 2.4; for a watch, three lines over
`Watch.next()` and `server.watch_take`.

## 3. The CLI

The CLI was nearly layered already; its commands just reached into other folders' files.

```
src/
  main.zig               the entry point
  term.zig               colors, bars, the cursor, the terminal's size        rank 0
  client.zig + client/   how a command reaches a server: local.zig today       rank 1
  view.zig + view/       a profile's report, live view and folded stacks;      rank 1
                         the processes table
  cmd.zig + cmd/         prof, ps, and the shared flags                         rank 2
```

`client` and `view` are beside each other: a view never asks the client, and the client never
prints. A command reads its flags, asks the client, and prints the answer through a view.

`client.zig` is the one door to a server:

```zig
pub const profile = local.profile;                 // a whole run, with a live view
pub const processes = local.processes;             // every process once, with its CPU
pub const processes_watch = local.processes_watch; // a frame every interval, until Ctrl-C
```

A remote client would be `client/remote.zig` with the same three functions; the commands would
not change. `process_name`, which only reads `/proc/<pid>/comm` for `prof`'s header, left the
client for `cmd/prof.zig`: it was never the server's business.

The client's polling got cheaper on the way: `server.processes` copies a frame, so the waiting
loop now copies into a scratch arena it resets, and only the frame it returns goes to the
caller's arena.

## 4. One rule, three modules

The layer test of Ep19 became a shared checker, `shared/layers.zig`. A module lists its layers
with a rank; the checker reads every source file and fails on an import past a facade, into a
layer beside, or into one above:

```zig
test "every layer of the server imports only its own files and the facades below it" {
    const found = try layers.check(.{ .base = "server", .layers = &.{
        .{ .name = "os", .rank = 0 },
        .{ .name = "windows", .rank = 1 },
        .{ .name = "symbols", .rank = 1 },
        .{ .name = "processes", .rank = 1 },
        .{ .name = "naming", .rank = 2 },
        .{ .name = "server", .rank = 3 },
        .{ .name = "control", .rank = 4 },
    } });
    try std.testing.expectEqual(@as(u32, 0), found);
}
```

The agent, the server and the CLI each have one such test. `Directory`, which the checker needs
to walk folders, moved from the agent's `os/` into `shared/`, and the agent's `os.zig` points at
it.

## 5. A bug the redesign made, and fixed

`nusku ps --interval 300` printed "every 0.2 s". The header shows the measured time between the
first two frames, and it was short: `Watch.init` armed the timer, but the first look happened
only at the first `next()`, after the controller had spawned its thread. The second frame's CPU
was measured over about 250 ms instead of 300.

The first look now happens inside `init`, and the timer is armed right after it; the first
`next()` returns that frame. The interval is whole however late the caller is. `Run` has no such
problem: its window's duration is counted from when sampling began, not from the timer.

## 6. The machine's CPU in `nusku ps`

The header used to add up the processes' `cpu_percent`, and take the number of CPUs from the
machine running the client. Both were wrong in the same way: the sum misses processes that ended
between two frames (a build starting hundreds of compilers loses most of its load), interrupts,
and steal; and the client's CPUs are not the agent's once the agent runs elsewhere.

The watch now sends the machine with every frame (agent §4.7 in Ep19), and the view only shows
it:

```
nusku ps  381 processes · 8 CPUs · CPU 52.5% (user 42.9 system 9.1 iowait 1.1) · memory 10.7G
```

The machine's CPU is a share of all CPUs, as `top` shows it; a process's is still a share of one
CPU, so a busy process can pass 100%. On the first frame the header says `CPU -`: there is no
look before to measure against. The server's `processes` layer stores the frame as it is, so it
needed no change.

The watch e2e test checks it against the machine: no CPU on the first frame, the CPU count the
system reports, the states adding up to busy, and room for the one core the burner keeps busy.
In one run the machine was 472% of one CPU while the processes added up to 452%: the 20% the sum
never saw.

## 7. Summary

- **The server takes events.** `Feed.take(protocol.RunEvent) → protocol.Answer` is the whole
  conversation with an agent run; `watch_take` with a watch. A network transport calls the
  same functions.
- **Five layers instead of one struct.** windows, symbols and processes, each with its own lock;
  naming, one function; server, the parent.
- **Jobs.** The controller starts, stops, waits for and polls a profile or a watch the same way,
  and `interrupt` stops everything from a signal handler.
- **The CLI in the same shape.** term, client, view, cmd; one client door with three functions.
- **One rule, checked on all three modules.**
- **The machine's CPU comes from the agent.** `/proc/stat`, in every watch frame; `ps` shows it.

The tests went from 231 to 241 without root, all passing.
