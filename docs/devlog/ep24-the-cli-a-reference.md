---
date: 2026-11-09
---

# Ep24: The CLI, a Reference

Ep22 is the agent and Ep23 the server. This is the third part: `nusku`, the program a person runs,
in `src/`. It is the smallest of the three, and the one that changes most often, since every new
command or view starts here.

1. [What the CLI is](#1-what-the-cli-is)
2. [The files](#2-the-files)
3. [The layers and who imports whom](#3-the-layers-and-who-imports-whom)
4. [Each layer](#4-each-layer)
5. [The commands](#5-the-commands)
6. [`nusku prof` from start to end](#6-nusku-prof-from-start-to-end)
7. [Extending the CLI](#7-extending-the-cli)
8. [Tests](#8-tests)

## 1. What the CLI is

```
nusku prof --pid 4242 --duration 10        profile a running process
nusku prof --exec ./app -- arg1 arg2       launch one and profile it from its first instruction
nusku ps                                   every process of the machine, live
```

A command does three things, always in this order: **read its flags**, **ask the client**, and
**print the answer through a view**. It never talks to the agent or the server itself. The
client is the one door to them; today it runs both in this process.

**The CLI is one of two clients.** The desktop app (`app/`, the `nusku-app` binary) is the other,
and both reach the same server through the same `client` module, at the repository's root. So
the client is not a layer of the CLI: anything a command can ask, the app can ask the same way.
They are two binaries on purpose: the CLI stays small, needs no npm to build, and runs on a
machine with no screen; the app carries WebUI and the React UI.

The CLI stands on modules of the repository that are not its layers:

| Module | What it gives |
|---|---|
| `client/` | how a program reaches a server: `profile`, `processes`, `processes_watch`, `stop` |
| `cli/` | the command-line parser: `cli.Command`, `cli.Flag`, `cli.Context`, `cli.execute` |
| `logger/` (`log`) | the logger: `--log-level`, `--log-format`, `--verbose`, `NO_COLOR` |

And it uses two more for types: `server` (what a profile is: `Profile`, `SymbolStack`, `Frame`)
and `shared` (the protocol: `ProcessFrame`, `Metric`, `RunStop`, …). A protocol type always comes
from `shared`, never through the server.

## 2. The files

```
src/
  main.zig       the entry point: the logger, then cli.execute(cmd.root)

  term/    term.zig     toolbox: ANSI styles, Style, bars, erasing lines, the terminal's size,
                        cutting text to a width
  view/    view.zig     toolbox: profile, processes
           profile.zig  a profile: the report, its live version, folded stacks
           processes.zig  the table of `nusku ps`
  cmd/     cmd.zig      the root command: its flags, its subcommands
           prof.zig     `nusku prof`
           ps.zig       `nusku ps`
           flags.zig    the flags more than one command reads
           interrupt.zig  Ctrl-C and SIGTERM: `client.stop()`

client/          at the repository's root: a module of its own, shared with app/
  client.zig     the door: profile, processes, processes_watch, stop
  local.zig      the server and the agent in this process
```

As in the agent and the server, the root holds only `main.zig`, and every layer is a folder with
its facade named like it.

## 3. The layers and who imports whom

```
   main.zig ─────── cmd.root, the logger
                │
   rank 2      cmd ─────────────────┐
                │                   │
   rank 1      view                 │
                │                   │
   rank 0      term          the client module ── server ── agent
```

| Layer | Rank | Imports | Is |
|---|---|---|---|
| `term` | 0 | nothing of the CLI | toolbox |
| `view` | 1 | term | toolbox: `profile`, `processes` |
| `cmd` | 2 | term, view, and the `client` module | the commands |

**A view never asks the client, and the client never prints.** A view is a function of what it
is given, so it can be tested with a profile made by hand; only `cmd` calls the client. The
client can be swapped for a remote one without touching a view, and the app draws the same
answers with React instead of `view`.

## 4. Each layer

### term: drawing on a terminal

**Why:** both views draw, with the same colors, bars, and redrawing in place.

| Tool | What it is for |
|---|---|
| `bold`, `dim`, `cyan`, `yellow`, `red`, … | ANSI codes |
| `Style` | `.on(code)`, `.off()`, `.heat(per_mille, red_from)`: codes only when color is on |
| `bar_write(w, per_mille, columns)` | a bar of eighths of a block: `████▉` |
| `lines_erase(w, lines)` | moves up and clears, so a live view draws over the last |
| `cursor_hide`, `cursor_show` | while a live table redraws |
| `size()` | the terminal's rows and columns, or null when not a terminal |
| `text_cut_write(w, text, width)` | a long command cut with `…` |

### The client module (client/ at the root)

Not a layer of the CLI, but what its commands ask, so it is described here.

**Why:** a program should not know how the profile is made: an agent on a thread here, or a
server across the network. Three functions, each a whole conversation, and a way to end one:

```zig
// The profile of a whole run, in `arena`. `stop` ends the run, and its profile still comes.
pub fn profile(gpa, arena, options: ProfileOptions, live: ?Live) !Result
// Every process once, with its CPU: the second look (the first has none).
pub fn processes(gpa, arena, interval_ms) !protocol.ProcessFrame
// A look every interval, shown to `live`, until `stop`.
pub fn processes_watch(gpa, interval_ms, live: ProcessesLive) !void
// Ends the call running now. Safe from any thread and from a signal handler.
pub fn stop() void
```

**Signals are the program's business, not the client's.** The CLI's `cmd/interrupt.zig` turns
Ctrl-C and SIGTERM into `client.stop()`, and keeps its handler for the rest of the program, so
a late second Ctrl-C (sudo passes one on twice) cannot end it before it prints. The app calls
`stop` when it wants to, and keeps the default Ctrl-C. A `stop` before a call has started its
job stops that job as soon as it starts. The client runs **one call at a time**; the app
serializes its calls with a lock.

| Type | What it is |
|---|---|
| `ProfileOptions` | `pid`, `metrics`, `interval_ms`, `duration_s`, `continue_target` (send SIGCONT once sampling has started) |
| `Live` | `context`, `every_ms`, `show(context, *Profile, elapsed_ms)`: called on the caller's thread with the profile so far |
| `Result` | `reason` (`RunStop`), `profile`, `elapsed_ms` |
| `ProcessesLive` | `context`, `show(context, *ProcessFrame)`: called with each new frame |

`local.zig` does it in this process:

1. A **backend** on the heap: a `Server` sized for the run (one target; enough windows for the
   whole duration, 600 for a run with no end, at most 3600) and a `Controller` with one job.
2. `controller.start(.profile)`, then SIGCONT to a launched target.
3. From here `stop` reaches the controller: `controller.interrupt()` stops the run, not the
   program, so the report still prints.
4. A wait loop every 50 ms: while the job runs, every `every_ms` it asks
   `server.profile(…, .as_they_are)` and shows it to `live`.
5. `controller.wait`, then the final `server.profile(…, .all_built)`: it waits for the last
   symbol tables, so the report is fully named.

The watch is the same: start a `.processes` job, poll `server.processes`, show each new frame
(not the first, which has no CPU). Each poll copies into a scratch arena it resets; only what is
returned goes to the caller's arena.

### view: what the commands print

**Why:** turning a profile or a frame into text is most of the CLI's code, and it must be
testable without running anything.

```zig
// view.profile
pub fn write(w, arena, profile, summary: Summary, options: Options) !void   // the report
pub fn live_write(w, arena, profile, summary, options, lines_before) !usize // drawn over the last
pub fn folded_write(w, arena, profile) !void                                // for flame graphs

// view.processes
pub fn write(w, arena, frame, options: Options) !usize   // the table; returns its lines
```

| Options | |
|---|---|
| `profile.Options` | `top` (20 functions), `cutoff_tenths` (call tree branches under 1.0% hidden), `color` |
| `profile.Summary` | `pid`, `name`, `elapsed_ms`, `reason` (null while live) |
| `processes.Options` | `top`, `width` (to cut commands), `sort` (cpu, mem, pid), `color`, `live` |

The report has a header, the **top functions** by self time (with their total), and the
**call tree** from the outermost frame, recursion folded (`↻`). The folded format is
`a;b;c count` per line, with named kernel frames marked `_[k]` as flame graph tools expect. The
processes table has a header with the machine's CPU (from the frame's `machine`, as `top`
shows it), then one row per process with a CPU bar; a process's CPU is a share of one CPU.

Each writer returns or takes the number of lines drawn, so the live versions can erase exactly
what they drew.

### cmd: the commands

**Why:** each command is a file, so adding one touches nothing else but the list.

`cmd.zig` is the root command `nusku`, its flags read by every command (`--verbose`,
`--log-level`, `--log-format`, with `NUSKU_LOG_LEVEL` / `NUSKU_LOG_FORMAT`), and its
subcommands. `flags.zig` holds what more than one command reads: `log_apply(ctx)`, the first
call of every `run`, and `--color` with `color_read(ctx)` (auto: a terminal without `NO_COLOR`).

## 5. The commands

### `nusku prof`

| Flag | Default | |
|---|---|---|
| `--pid`, `-p` | | a running process |
| `--exec`, `-e` + `-- args` | | launch one: stopped right after its exec, continued once sampling started, so even its start is profiled; stopped with the profile if still running |
| `--metrics` | `cpu` | comma-separated; only `cpu` exists so far |
| `--interval` | 1000 | ms between reports (10 ms to an hour): how often the live view updates |
| `--duration` | 0 | seconds; 0 until the process exits or Ctrl-C |
| `--top` | 20 | functions in the table |
| `--cutoff` | 1 | % under which call tree branches are hidden |
| `--no-live` | | only the final report |
| `--folded FILE` | | also write folded stacks |
| `--color` | auto | |

Errors the user can fix come with a hint: permission (root, or CAP_BPF, CAP_PERFMON,
CAP_SYSLOG), no such process, a kernel older than 5.3, a metric not built yet.

### `nusku ps`

| Flag | Default | |
|---|---|---|
| `--interval` | 1000 | ms between looks (100 ms to a minute); CPU is measured over it |
| `--top` | what fits the screen, or 20 | 0 shows all |
| `--sort` | `cpu` | `cpu`, `mem`, `pid` |
| `--once` | | print once and exit, even on a terminal |
| `--color` | auto | |

On a terminal it redraws until Ctrl-C with the cursor hidden; otherwise it prints once.

## 6. `nusku prof` from start to end

```
main            logger; cli.execute → prof.run
prof.run        flags.log_apply; settings_read (every flag checked, usage errors here)
                --exec: launch → spawn, SIGSTOP right after the exec
                the name: the exec's basename, or /proc/<pid>/comm
client.profile  backend: Server + Controller
                controller.start(.profile)          the agent loads, about a second
                SIGCONT to a launched target        sampling has started: nothing missed
                Ctrl-C → controller.interrupt
                every --interval: server.profile(.as_they_are) → Live.show
                                  → view.live_write over the last view
                the run stops (duration, exit, Ctrl-C)
                server.profile(.all_built)          the last tables built, every name in
prof.run        --folded: view.folded_write to the file
                erase the live view; view.write the report
                a launched target still running: SIGCONT, then killed
```

## 7. Extending the CLI

### A new command

1. `cmd/name.zig` with `pub const cmd: cli.Command` and its `run`. `run` starts with
   `flags.log_apply(ctx)`, checks every flag (`ctx.usageFail` with what was given), asks the
   client, and prints through a view.
2. Add it to `subcommands` and the test block in `cmd/cmd.zig`.
3. A flag a second command needs moves to `cmd/flags.zig`.

### A new view

A file in `view/`, named in `view/view.zig`. It writes to a `*Writer` from what it is given
(a profile, a frame), returns the lines it drew if it is shown live, and uses `term` for color.
It never calls the client. Test it with data made by hand, as `view/processes.zig` does.

### A new question to the server

A function in `client/local.zig` (at the root) that starts a job or queries the server, exported
from `client/client.zig`. If the server cannot answer it yet, that starts with a query on
`Server` (Ep23 §9). The command then calls `client.name`, never the server, and the app gets
it with one binding in `app/src/api.zig`.

### A new metric

`--metrics` already parses every `protocol.Metric`; once the agent and server have it (Ep22 §7,
Ep23 §9), the CLI needs a view for it, and `hint` drops it from "only the cpu metric exists".

### A remote server (gRPC, …)

1. `client/remote.zig` with the same functions as `local.zig`, talking to a server over the
   network.
2. `client/client.zig` picks one (a `--server` flag or an environment variable).

No command, no view, and nothing in the app changes: they only know `client.profile`,
`client.processes`, `client.processes_watch` and `client.stop`. It is also what lets the app
run as a normal user: the server with the agent runs as root, the app does not.

### A new layer

A folder `name/` with `name/name.zig`, its rank one above what it imports, nothing beside it,
named for what it gives, and its line in `main.zig`'s list and test block.

## 8. Tests

| Where | What |
|---|---|
| `view/*.zig` | the views from data made by hand: headers, sorting, cutting, colors off, the folded format, the lines returned |
| `term/term.zig` | bars and cuts |
| `client/local.zig` | what is pure: how many windows a run keeps (its own test step) |
| `cmd/*.zig` | none yet: a command is thin. Checking its flags (`settings_read`, `top_read`) is where a test would start |
| `testing/` (repo root) | `make check`: the real `nusku prof` against apps with known profiles, and `nusku prof --exec` on a process that exits early |

The client's real work (an agent, a server, threads) is tested where it lives: the server's
`control` tests and the end-to-end checks in `testing/`. A view or a command should never need
root to be tested.
