---
date: 2026-11-08
---

# Ep21: The Rules of the Project

This episode is a reference, not a story. It collects the rules Nusku's code follows, so that
new code reads like the old, and so that adding a feature means following a recipe instead of
redesigning. When in doubt, look for the closest existing example and do the same.

It is organised by question:

1. [How the project is shaped](#1-the-shape) and where new code goes.
2. [The rule of the layers](#2-the-rule-of-the-layers).
3. [How an API looks](#3-how-an-api-looks).
4. [How code looks](#4-how-code-looks): names, size, assertions, limits, errors, memory.
5. [How comments look](#5-how-comments-look).
6. [How logs look](#6-how-logs-look).
7. [How tests look](#7-how-tests-look).
8. [How to build, test and commit](#8-building-testing-committing).
9. [Recipes](#9-recipes): a metric, a layer, a protocol type, a query, a command, a transport.
10. [The checklist](#10-the-checklist) before calling something done.

## 1. The shape

```
shared/   what every module uses: the protocol, ELF, files, the layer checker
agent/    profiles a process with eBPF, watches every process; sends raw addresses
server/   keeps the reports, names them with the binaries' symbols, answers with profiles
src/      the nusku program: commands, views, and the client that reaches the server
cli/      the command-line parser src/ is built on
logger/   the logger every module logs through
testing/  small C, Go and Zig apps with known profiles, and the Makefile that checks them
app/      the UI, with its own build (not part of build.zig)
```

Each module has one way in:

| Module | What it exposes |
|---|---|
| `agent` | `Run` (init · deinit · next · stop · binary_want) and `Watch` (init · deinit · next · stop) |
| `server` | `Server` (feed · watch_take · profile · processes), `Feed` (take · close), `Controller` (start · stop · wait · running · interrupt) |
| `shared` | `protocol`, `elf`, `File`, `directory`, `layers` |
| `src` | the `nusku` program |

What crosses between the agent and the server is a `shared/protocol` type, never an agent or a
server type. The agent never imports the server; the server imports the agent only in its
`control` layer, the local client.

**A shared type is imported from `shared`, by every module, the CLI too.** No module re-exports
it: `server.ProcessFrame` would make the CLI depend on the server for a type the server does not
own, and hide where the type lives. The CLI writes `@import("shared").protocol.ProcessFrame`;
it takes from `server` only what the server defines (`Profile`, `Frame`, `Controller`, ...).

## 2. The rule of the layers

Every module is made of layers. A layer is **a file and a folder of the same name**:
`target.zig` and `target/`. A small layer is just the file.

- **The file is the facade.** It is the only file of the layer another layer may import. It
  holds the layer's **one struct**, with `init`, `deinit` and one to four functions that do the
  job, plus the few types that struct takes and gives. A layer of small unrelated tools (`os`,
  `elf`, `term`, `view`) is a **toolbox**: its facade lists the tools by name instead.
- **The folder is the layer's own business.** Its files import each other freely.
- **A layer imports only layers below it**, and only their facades.
- **Layers of the same rank never import each other.** They do not know the others exist.
- **Only the parent puts layers together**: files in no layer (`run.zig`, `root.zig`,
  `main.zig`) may import every facade.
- **Anyone may import** `log.zig`, the `std`, `shared` and other named modules, and test
  helpers in `testing/`.

The ranks today, bottom up:

| agent | server | src |
|---|---|---|
| 0 `os` | 0 `os` | 0 `term` |
| 1 `elf` | 1 `windows`, `symbols`, `processes` | 1 `client`, `view` |
| 2 `target` | 2 `naming` | 2 `cmd` |
| 3 `unwind` | 3 `server` | parent: `main.zig` |
| 4 `ebpf`, `symbols`, `processes` | 4 `control` | |
| parent: `run`, `watch`, `message`, `root` | parent: `root.zig` | |

**The rule is a test.** `shared/layers.zig` reads every source file of a module and fails on an
import past a facade, into a layer beside, or into one above, naming the line. Each module has a
test listing its ranks: `agent/testing/layers.zig`, `server/testing/layers.zig`,
`src/testing/layers.zig`. A new layer is one line there.

When the rule seems to get in the way, it is usually saying something true:

- *Two layers beside each other need the same thing:* that thing is a layer below both. (The ELF
  reader was in `unwind/` and `symbols/` borrowed it; it became `elf`.)
- *A layer needs something from a layer beside it:* the parent should pass it. (`Symbols` gets
  the vDSO image from the `Target` the parent hands it, not from `ebpf`.)
- *A test needs another layer's insides:* use the facade. (A test needing this process's regions
  calls `Target.init(gpa, current_pid)`.)

## 3. How an API looks

### init and deinit

- `init` checks everything it can **before** allocating or loading anything, and refuses a bad
  option with an error named after it: `InvalidPid`, `InvalidInterval`, `NoMetrics`.
- `init` returns the value (`Run.init(gpa, options) !Run`) when the struct may move. It takes a
  pointer (`ebpf.init(gpa, …) !void`) when something points into it (a thread, a collector,
  a ring reader); its doc says it must stay at its address until `deinit`.
- `deinit` never fails, frees in the reverse order of `init`, and ends with `x.* = undefined`.
- Every step of `init` that holds something is followed by its `errdefer`.

### Pull, not callbacks

Something that produces a stream is pulled: `next()` returns the next event, waiting for it,
and null after the last. The caller owns the loop, on whatever thread it likes, and `switch`es
over a union: the compiler checks every event is handled. `stop()` ends the stream at its next
wait, and is safe from any thread and from a signal handler (one eventfd write).

```zig
var run = try agent.Run.init(gpa, .{ .pid = pid });
defer run.deinit();
while (try run.next()) |event| switch (event) { ... };
```

Something that consumes a stream takes one event and gives back what to answer:
`Feed.take(event) !Answer`. No comptime hooks, no context pointers.

### Lifetimes are said, every time

Every value that points into someone's buffers says how long it lives, in its doc:
"valid until the next `next`", "points into `arena`", "good until the next `put`". The caller
copies what it keeps (`Message.clone`). A function that copies says where: "copied into
`arena`".

### Options

Options are a struct with defaults for everything but what has no sensible default (a pid).
Each field says its unit and what 0 means: `duration_s: u32 = 0, // 0: until the target exits`.

## 4. How code looks

### Names

- `snake_case` for functions, variables and fields; `PascalCase` for types; files `snake_case`.
- **The noun first, then the verb**: `regions_see`, `target_add`, `binary_want`, `kernel_read`,
  `window_resolve`. Related functions sort together.
- **Units in the name**: `_ns`, `_ms`, `_s`, `_bytes`, `_kib`, `_mib`. A time is `start_unix_ns`
  or `window_start_monotonic_ns`: which clock, too.
- **Limits** end in `_max`, counts in `_count`: `binaries_max`, `pending_count`.
- No abbreviations a reader must decode: `previous`, not `prev`; `index`, not `idx`. Short
  names for short scopes only.
- A parameter is named after its type: `run: *Run`, `symbols: *Symbols`, not `self`.

### Size

- **Lines of at most 100 columns.** Break a long call into a local or one argument per line.
- **Functions of at most 70 lines.** Past that, split by what the parts do, and name them.
- `zig fmt` on everything.

### Assertions

Assert what must be true, at both ends: arguments on the way in, the result on the way out, and
the same fact on both sides of a boundary (the pair assertion: the writer asserts what it
writes, the reader asserts what it reads). An assertion is not error handling: a bad input from
outside is an error; a broken invariant inside is an assertion. The agent and the server have
over 200.

```zig
assert(transfer.stage != .done);
assert(buffer.len > 0);
...
assert(filled == count);
```

### Limits

Everything is bounded, and every bound is a named constant with the reason for its number:

```zig
/// At 99 Hz on 64 CPUs a tick sees at most 634 samples: the ring cannot fill between two.
const tick_ms_max = 100;
/// Bytes of /proc/kallsyms read per loop round: about 12 ms of the kernel's time. Read in one
/// go, it would hold up the loop for more than half a second.
pub const kallsyms_bytes_per_round = 256 * 1024;
```

- **Every loop is bounded or waits.** An event loop waits on poll every round, so it cannot spin.
- **Work per round is bounded**: a few chunks per tick, a piece of a file per step. Nothing holds
  a loop for longer than its tick.
- **Full means refuse, not grow**: a queue that is full refuses, and says so once.

### Memory

- Allocate at `init`; not per report, per sample or per frame. A ring of fixed slots, a buffer
  sized once.
- Per-window memory lives in an arena reset with `.retain_capacity`: a steady target stops
  allocating after the first window.
- Large structs go on the heap (`gpa.create`), not the stack.
- Tests use `testing.allocator`, so a leak fails the test.

### Errors

- **A part failing drops that part, not the whole.** A binary that cannot be sent is dropped and
  the run goes on; a window too big is counted and the run goes on. Only what makes the whole
  meaningless stops it.
- Errors are named for what happened: `ProcessNotFound`, `WindowTooLarge`, `AlreadyKnown`.
- Everything from outside is untrusted and checked: a file's offsets, an upload's chunks against
  its header, `/proc`'s lines.

### Small things

- No commented-out code, no `TODO` left in a commit.
- No global state, except what a signal handler must reach (and then written outside the
  handler only).

## 5. How comments look

Comments are sentences, in plain words, and say **what** and **why**, not how; the code says
how.

- **Every file starts with `//!`**: what it is, in a line or two, and for a facade the folder's
  files with one line each. A facade's header shows how to use it, as code.
- **Every public declaration has `///`** saying what it is or does, and anything a caller must
  know: lifetimes, what null means, errors that matter, whether it is safe from another thread.
- **A number gets its reason**, a choice gets its alternative: "99, not 100, so sampling does not
  run in lockstep with work on a 10 ms timer".
- No "this function…", no restating the name: `/// Drops a binary still arriving.` not
  `/// This function deinitializes the receiver.`
- Short. A comment that needs a paragraph is often a design that needs a devlog.

```zig
//! One binary on its way: `step` gives its next part, the header, a chunk, or the end.

/// Whether the header went out: a transfer dropped after it must be aborted.
pub fn begun(transfer: *const Transfer) bool {
```

## 6. How logs look

Each module logs under its scope, through its `log.zig`:

```zig
const log = @import("log.zig").agent;      // or .server
log.warn("binary refused: too big to receive", .{ .path = header.path, .kib = kib });
```

- **The message is lowercase, says what happened, then why after a colon**: "binary not sent: it
  cannot be opened", "target is gone: keeping its last regions".
- **Facts go in fields**, never in the message: `.pid = pid`, `.cause = err`, `.kib = …`. Sizes in
  `kib` or `mib` (`log_file.kib(bytes)` rounds up), times in `_ms` or `_s`.
- **Levels mean something:**
  - `err`: the whole thing failed (a run, the server). Once.
  - `warn`: something is lost or degraded, and the user may want to act (`needs = "CAP_SYSLOG"`).
  - `info`: a lifecycle step: started, stopped, with the numbers that sum it up.
  - `debug`: what a developer follows: each binary, each table.
- **A repeated problem is said once**: the first window too big, the first time a table is full.
  Counts go in the stop line.

## 7. How tests look

- **Tests are at the bottom of the file they test**, after the separator line:

  ```zig
  // ------------------------------------------------------------------------------------- tests
  ```

- **A test's name is a sentence about behaviour**: `"a binary that cannot be opened is dropped,
  not retried"`, `"stop ends the run at its next wait, with its last report"`.
- **Each facade's test block lists its folder's files**, so a file is tested as soon as its layer
  is. The module root's test block lists the facades.
- **A test that needs root says so in its name, `(root)`, and skips without it**: it returns
  `error.SkipZigTest` on `PermissionDenied`, so the suite stays green for anyone.
- **End to end tests** are in `testing/e2e/`, against real processes (children the test spawns,
  named with `prctl`) with a behaviour known in advance. They print one summary line of what they
  measured, so a failure says how far off it was.
- **Examples are tests.** The usage example of the agent (`testing/examples/server_feed.zig`) is
  compiled and run with every build, so it cannot go stale.
- **The main code stays light: test-only code lives in `testing/`.** A file's own tests sit at
  its bottom; a helper that tests of other files need (fixtures, fake binaries, waiting for a
  zombie) goes in the module's `testing/` folder, never in a main file, not even as a `pub fn`
  "for testing". Test helpers may import anything; nothing but tests imports them.
- Bounds in tests are loose enough for a loaded machine, and a test never sleeps hoping: it polls
  for the condition, with a limit.

## 8. Building, testing, committing

```
zig build                 build nusku, the tests' binaries and the BPF objects
zig build test            every test; the root ones skip
sudo zig build test       every test, the root ones too
zig-out/bin/agent-tests   the agent's tests alone (installed by `zig build test`), e.g. with sudo
zig fmt --check agent server shared src
cd testing && make check  profile the C, Go and Zig apps and check their known profiles (sudo)
```

- **The machine has 7.6 GiB of RAM**: cap heavy builds,
  `systemd-run --user --scope -p MemoryMax=5G zig build test`, and avoid big comptime
  concatenations.
- **Green after every step.** A change made of steps (move, then rewire, then remove) builds and
  passes between each.
- **A commit message is one line**, saying what changed, in lowercase.
- `app/` builds on its own, with its own tooling.

## 9. Recipes

### A new metric (off-CPU, memory, …)

All in the `ebpf` layer; nothing below it changes.

1. A folder `agent/ebpf/offcpu/`: its program in `agent/ebpf/kernel/offcpu.bpf.zig` (added in
   `agent/build.zig` with `add_kernel_program`), its collector with `init`, `deinit`, `start`,
   `tick`, `collect`, like `ebpf/cpu/collector.zig`. A walking program binds the unwind maps
   (`UnwindMaps.bindings()`).
2. In `ebpf.zig`: a field `offcpu: ?OffcpuCollector`, a line in `init`, `deinit`, `tick` and
   `collect`, and a field `offcpu: ?OffcpuWindow` in `Windows`. Remove it from the
   `MetricNotImplemented` list.
3. In `shared/protocol`: what a message carries for it.
4. In `agent/message.zig`: the window into the message.
5. In `server/naming`: if its stacks are named the same way, nothing; otherwise its own step.

### A new file in a layer

Put it in the layer's folder, import it from the facade (or a sibling), and add it to the
facade's test block. If another layer needs it, export what it needs from the facade.

### A new layer

1. `name.zig` with the struct and its header, and `name/` if it has more than one file.
2. Pick its rank: the highest rank of what it imports, plus one. Check it imports nothing beside.
3. A line in the module's `testing/layers.zig`, and in the root's layer list and test block.

### A new type between the agent and the server

It goes in `shared/protocol/`, exported from `shared/protocol.zig`. The agent fills it, the
server reads it, the CLI shows it; each imports it from `shared`, and none defines or
re-exports its own copy. A new event is a new field of `RunEvent` or
`WatchEvent`: the compiler then points at every `switch` that must handle it.

### A new query on the server

A function on `Server` that asks its layers: copy what it needs under each layer's lock, compute
without any lock. If it is new computation (not just a copy), it is a new layer above the ones it
reads, like `naming`.

### A new command

A file in `src/cmd/` with its `cli.Command`, listed in `cmd.zig`'s subcommands and test block. It
reads its flags (`cmd/flags.zig` for the shared ones), asks `client.zig`, and prints through a
view; a new view goes in `src/view/`, exported from `view.zig`.

### A remote transport (gRPC)

Nothing in the agent or the server's layers changes:

- **Agent side:** a program that runs `Run.next()`, sends each `protocol.RunEvent`, and applies
  each `protocol.Answer` it gets back with `binary_want`.
- **Server side:** a receiver that opens a `Feed` per agent run and calls `feed.take(event)`,
  sending the answer back; `watch_take` for a watch. It is a layer beside `control`.
- **CLI side:** `src/client/remote.zig` with the same three functions as `local.zig`, and
  `client.zig` choosing one.

## 10. The checklist

Before calling something done:

- [ ] `zig build test` passes; `sudo zig build test` too, if it touches the agent or a root test.
- [ ] `zig fmt --check` is clean; no line over 100 columns, no function over 70 lines.
- [ ] The layer tests pass: no import past a facade, beside, or above.
- [ ] Every new bound is a named constant with its reason; every loop is bounded or waits.
- [ ] Every new public declaration has a doc comment, with its lifetimes.
- [ ] Logs follow the message style, with facts in fields, a repeated problem said once.
- [ ] New behaviour has a test named as a sentence; a root one says `(root)` and skips without.
- [ ] Nothing that points into a buffer outlives it without being copied.
- [ ] A devlog episode, if the design changed.
