---
date: 2026-11-11
---

# Ep26: One Server, Two Clients

*For each part on its own, see the references: the agent (Ep22), the server (Ep23), the CLI
(Ep24) and shared (Ep25). This episode is how they fit together now that there is a second
client, the desktop app, and what was built to get there.*

Until now there was one way to use Nusku: the CLI. This episode adds the desktop app as a
second client of the same server, and the pieces that came with it:

- A `client` module at the root, used by the CLI and the app alike.
- Machine-wide CPU from `/proc/stat`, sent with every processes frame.
- A **session**: one server that lives as long as the app, profiling many processes at once,
  with the processes watch running beside them.
- Profiles that are **shared**: a second client asking for the same process joins the run
  instead of starting another, and the run ends when the last one leaves.
- The app: a Zig backend over WebUI, and a React UI that loads once and stays.

1. [The picture](#1-the-picture)
2. [The server, in one page](#2-the-server-in-one-page)
3. [The client module](#3-the-client-module)
4. [The session](#4-the-session)
5. [Sharing a profile](#5-sharing-a-profile)
6. [Stopping never touches the process](#6-stopping-never-touches-the-process)
7. [The app's backend](#7-the-apps-backend)
8. [The app's UI](#8-the-apps-ui)
9. [Machine CPU](#9-machine-cpu)
10. [Threads and locks](#10-threads-and-locks)
11. [Bugs on the way](#11-bugs-on-the-way)
12. [What is left](#12-what-is-left)

## 1. The picture

```
   nusku (CLI)                         nusku-app (desktop)
   ───────────                         ───────────────────
   cmd: prof, ps                       React UI  (pages, polling providers)
        │                                   │  webui.call(...)  JSON
        │                              api: get_processes, profile_start,
        │                                   profile_stop, profile_stream
        ▼                                   ▼
   client.profile / client.processes   client.Session   (one per app)
   (one server per call)                    │
        └───────────────┬───────────────────┘
                        ▼
              server: Controller ── jobs on threads
                        │                 │
                        ▼                 ▼
                     Server  ◀──feed── agent.Run / agent.Watch
                  (windows, symbols,      (eBPF, /proc)
                   processes, naming)
```

Both clients go through `client/`. Neither talks to the agent: the controller runs the agent
as **jobs** on threads and feeds the server. A client only starts jobs, stops them and asks
the server for profiles and frames.

Today every client runs the server **inside its own process**. The CLI and the app do not share
a server; they share the code. A server of its own, that both reach over a socket, is the next
step (section 12), and the client module is where it will plug in.

## 2. The server, in one page

Ep23 has it in full. What matters for the clients:

| Piece | What it does |
|---|---|
| `Server` | Keeps what the agents report: a ring of **windows** per target, the binaries' **symbols**, the newest **processes** frame. Answers `profile(arena, query, names)` and `processes(arena)`. |
| `Feed` | One per profile run: takes the agent's events, answers its binary offers. |
| `Controller` | Runs **jobs**: `start(spec)` gives a job id (and a target id for a profile) at once; `stop(job)`, `wait(job)`, `running(job)`. Up to `jobs_max` jobs, each on its own thread. |

Two things the server already did, and that the session builds on:

- **Many targets at once.** Each profile is its own target with its own ring. A target that
  ends is marked finished and stays readable. When the store is full, the oldest finished
  target makes room; a running one never does.
- **Reading while it runs.** `server.profile` copies a target's windows under the windows' lock
  and names them, so a profile can be read as often as wanted while the job feeds it.

## 3. The client module

`client/` sits at the root because two programs use it. The root `build.zig` exports it with
`b.addModule("client", …)`, and the app gets it through its `build.zig.zon`
(`.nusku = .{ .path = ".." }`).

It has two ways in:

| | For | How it runs |
|---|---|---|
| `client.profile`, `client.processes`, `client.processes_watch`, `client.stop` | the CLI | One call is one server: built, used, torn down. `profile` blocks until the run ends; `stop` is signal-safe, for Ctrl-C. |
| `client.Session` | the app | One server for the life of the program. Calls return at once. |

The one-shot calls fit a command that does one thing and exits. They do not fit an app: a new
server for each processes poll cost about a second per call, and `client.stop` is one global
flag, so with two runs in a process it stops whichever registered last. The session is the
answer to both.

## 4. The session

`client/session.zig`:

```zig
var session: client.Session = undefined;            // must stay at its address
try session.init(gpa, .{});                         // profiles_max 8, windows_per_profile 600,
defer session.deinit();                             // processes_interval_ms 1000

const started = try session.profile_start(options, user);   // { job, joined }
const stopped = try session.profile_stop(started.job, user);// { reason, users }
session.user_leave(user);                                   // a client went away
const states = try session.profiles(arena);                 // []ProfileState
const frame = try session.processes(arena);                 // ?ProcessFrame
```

Inside, it owns one `Server`, one `Controller` (with `profiles_max + 1` jobs: one for the
watch) and a list of **entries**, one per profile it started:

```
Entry { job, target, pid, started_ms, ended_ms, reason, failure, users[8], users_count }
```

How each call works:

- **`profile_start`** first reaps (below). If a running entry has the same pid, the caller
  joins it (section 5). Otherwise, if the list is full, the oldest *ended* entry is dropped,
  and if none has ended the answer is `ProfilesFull`. Then the controller starts the job.
- **`profile_stop`** removes the caller from the entry. The job is stopped only when no user
  is left. Asking again after it ended gives the same reason.
- **`profiles`** reaps, copies the entries, **lets go of the lock**, then builds each profile.
  A running profile is built with the names found so far (`.as_they_are`); an ended one waits
  for all of them (`.all_built`). Building outside the lock means a slow symbol build never
  holds up a start or a stop.
- **`processes`** starts the watch job the first time and keeps it running, then reads the
  newest frame. No wait per call: it went from about 1 s to 5 ms.
- **Reaping**: a run can end on its own, when the process exits or the duration is over. The
  controller keeps such a job until someone calls `wait`. Reaping does that for every entry
  whose job is no longer running, and records its reason. The entry stays in the list, with
  `running = false` and its last profile, so the UI sees how it ended.

What the UI gets for each profile:

```zig
ProfileState { job, pid, running, users, elapsed_ms, reason, failure, profile }
```

A profile keeps its last `windows_per_profile` windows: ten minutes at one report a second.
A longer run shows its last ten minutes. The CLI already worked this way for runs with no
duration.

## 5. Sharing a profile

Profiling the same process twice would double the eBPF work for the same data. So a second
`profile_start` for a pid that is already running does no setup: it adds the caller as a
**user** of the running entry and answers `{ job, joined: true }` with the same job id. Its
own metrics and interval are ignored; it gets the data of the run that is there.

The rules:

| Call | Effect |
|---|---|
| start, pid not profiled | new job, user added, `joined: false` |
| start, pid running | user added to that entry, `joined: true` |
| start again by the same user | nothing new, same job |
| stop by a user, others left | user removed, `reason: null`, `users: n` |
| stop by the last user | job stopped, `reason` set |
| stop by a user that never joined | `NotJoined` |
| the user goes away | `user_leave`: removed from every entry, an entry left empty stops |

In the app, a **user is a page**: WebUI's `client_id`. When a page disconnects, the app calls
`user_leave` with its id, so a closed window gives up its share and does not keep a profile
running forever.

Sharing works between all the pages of one app, because they use one session. The CLI and the
app are two processes with two servers, so they cannot share a profile until the server runs
on its own.

## 6. Stopping never touches the process

Stopping a profile cancels the agent's own timers and eBPF; it sends the process no signal,
does not trace it and does not pause it. Tested on a busy shell loop: profiled, stopped, still
running at 100% CPU.

The one place the project kills a process is `nusku prof <program>`: the CLI launched that
program itself (stopped, so no sample is missed), and kills it when the profile ends. With
`--pid`, nothing is killed.

## 7. The app's backend

`app/` has its own `build.zig`. It is a client like the CLI, not part of the root build.

```
app/src/
  main.zig            the window: multi-client, size, the bindings, dev or embedded UI
  static.zig          serves the built UI from the binary
  api/
    api.zig           binds the calls, creates and frees the session
    session.zig       the app's one client.Session
    processes.zig     get_processes
    profile.zig       profile_start, profile_stop, profile_stream, and the disconnect handler
    json.zig          a value or an error, as JSON
```

The calls the UI makes:

| Call | Argument | Answer |
|---|---|---|
| `get_processes` | none | a processes frame, with `machine` |
| `profile_start` | `{"pid":1234,"metrics":"cpu,offcpu","interval_ms":1000,"duration_s":0}` (only `pid` is required) | `{"job":3,"pid":1234,"joined":false}` |
| `profile_stop` | the job id | `{"job":3,"reason":"cancelled","users":0}` |
| `profile_stream` | none | `[{job, pid, running, users, elapsed_ms, reason, failure, profile}, …]` |

Every error comes back as `{"error":"Name"}`, and the UI's `call()` turns it into a thrown
error. The ones to expect: `InvalidRequest`, `InvalidPid`, `InvalidInterval`,
`UnknownMetric`, `NoMetrics`, `ProfilesFull`, `UsersFull`, `ProfileUnknown`, `NotJoined`,
`NoFrameYet`, and `PermissionDenied` when the app does not run as root.

`get_processes` waits up to three seconds for the first frame after start; after that it
answers at once. The first frame has no CPU numbers (CPU needs two looks), and the UI shows
"—" until the second.

**Multi-client.** `main.zig` sets WebUI's `multi_client` before anything else. Without it,
WebUI hands `webui.js` to one page only: a second window, or a browser tab on the Vite dev
server, got a 403, had no bridge, and showed "The backend is not running". Now every page has
the bridge, and each answer goes back to the page that asked.

**Dev mode.** `zig build run -Ddev` loads the UI from Vite at `127.0.0.1:5173`, which proxies
`/webui.js` to the app on port 9000. One app process holds that port, so for a second window
open the Vite address; a second dev process fails with `PortError`. The release build picks a
free port each time.

## 8. The app's UI

React 19, in `app/ui/src`:

- **`lib/backend.ts`** is the bridge. It waits for WebUI to be connected before any call, so
  the first call no longer fails with a socket error at startup.
- **`components/machine-provider.tsx`** polls `get_processes` once a second from the moment
  the app starts, and keeps a minute of CPU history. Pages read it with `useMachine()`.
- **`App.tsx`** keeps every page mounted with `<Activity>`. Moving between pages shows them;
  nothing reloads and nothing is fetched again.
- **`pages/processes.tsx`** draws only the rows on screen (`useVisibleRows`). With 400 rows
  drawn on every update, switching pages took up to 1.4 s; now 40 to 85 ms.
- **`components/cpu-chart.tsx`** is a stacked area of the machine's CPU over the last minute,
  growing from left to right, with a crosshair tooltip. **`machine-panel.tsx`** shows the
  numbers beside it: busy, CPUs, processes, threads, memory.

Profiling is not in the UI yet: the three calls are there for it.

## 9. Machine CPU

`agent/processes/machine.zig` reads the first line of `/proc/stat` (the whole machine) and
counts the `cpuN` lines. Each look is subtracted from the one before; a counter that went
back gives 0, not a wrap:

```
busy%   = (Δtotal − Δidle − Δiowait) / Δtotal
user%   = (Δuser + Δnice) / Δtotal
system%, iowait%, irq% (irq + softirq), steal%  the same way
```

It travels in the frame as `machine: { cpus, cpu: ?MachineCpu }`, `null` on the first look.
The types are in `shared/protocol/processes.zig`, imported by every module from `shared`;
the server does not re-export them.

## 10. Threads and locks

| Lock | Guards |
|---|---|
| the session's mutex | the entries and the controller: start, stop, reap, leave |
| the server's own locks (Ep23) | windows, symbols, processes frame |

- WebUI runs each call on a thread of its own, so calls from two pages can arrive together.
  The session's lock covers everything they share; the app needs no lock of its own.
- `profiles()` and `processes()` read the server outside the session's lock. The server's
  layers lock themselves.
- `profile_stop` joins the job's thread while holding the session's lock. It is short: the
  agent sees the cancel at its next poll.

## 11. Bugs on the way

- **"Cannot reach the backend"** on a second window: WebUI's one-client default (section 7).
- **ZLS could not find `webui` or `build_options`.** The Vite build step printed to stdout,
  where ZLS reads the build runner's JSON. It now prints to stderr.
- **A socket error at startup**: calls left before WebUI was connected. They wait now.
- **A blank page without the bridge**: the bridge was required; it is optional now, and the
  page says what is wrong.
- **Lag between pages**: every page fetched again, and every row was drawn. Fixed by the
  provider, `<Activity>` and the virtual table.
- **The review of the first `profile.zig`**: metrics were trimmed of nothing (`""` instead of
  `" "`), the request was freed twice, and nothing was bound, which hid it from the
  compiler: Zig only compiles what is used.

## 12. What is left

- **A server of its own.** Today the CLI and the app each have a server inside. Running it as
  a process of its own, reached over a socket, would let them share profiles and let the app
  run without root. The session is shaped for it: the same calls, sent over a wire.
- **Profiling in the UI**: a start button on the processes table, a list of running profiles
  from `profile_stream`, a stop button, and a view of the stacks.
- **Refresh drops a share.** A refresh is a disconnect, so a page that was the only user stops
  its profile. Waiting a few seconds before leaving, and staying if the same client comes back,
  would fix it.
- **Big numbers.** A frame's `address` can be above 2^53, which JavaScript cannot hold
  exactly. Fine for showing; send it as hex if it must be exact.
- **The stream's size.** Every profile's full stacks on every poll will get heavy. The top N
  stacks, or only what changed, when it does.
