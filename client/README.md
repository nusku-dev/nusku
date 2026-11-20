# client

How a program reaches nusku. Both front ends use this module and nothing below it:
[`nusku-cli`](../src/README.md) and [`nusku-app`/`nusku-web`](../app/README.md). Whatever one
of them can do, the other asks for the same way.

Today the client starts the [`server`](../server/README.md) and its agents inside the same
process, so a program that imports `client` is a whole profiler. When the server runs on its
own one day, this is the module that will talk to it, and the front ends won't change.

It also has what both front ends need around a profile:
- saving runs to disk;
- packing a profile for the wire.

## Public API

Everything is in `client.zig`. There are two ways to profile.

**One-shot: `profile`, for a single run start to end.** This is what `nusku-cli prof` uses.

```zig
const client = @import("client");

const result = try client.profile(gpa, arena, .{
    .pid = pid,                       // or .program = .{ .argv = argv }: the agent starts it
    .metrics = .initOne(.cpu),
    .interval_ms = 1000,
    .duration_s = 10,                 // 0: until the process exits or client.stop()
}, live);                             // optional: called every `every_ms` with the profile so far
// result.profile: named stacks; result.reason: why it ended; result.pid; result.elapsed_ms
```

`client.stop()` ends it from a signal handler (Ctrl-C). `processes` and `processes_watch` do
the same for the machine's process table.

**Long-lived: `Session`, many jobs at once.** This is what `nusku-cli watch` and the app use.

```zig
var session: client.Session = undefined;
try session.init(gpa, .{});
defer session.deinit();

const started = try session.profile_start(.{ .pid = pid, ... }, user);
const delta = try session.profile_get(arena, started.job, since);  // what changed since `since`
                                                                  // (0: all), or null: nothing
_ = try session.profile_stop(started.job, user);
```

| `Session` call | |
|---|---|
| `profile_start`, `profile_stop` | profile a running process (`pid`), or a program the agent launches (`program`: its `argv`, and `keep_running`). `Started` has the pid either way |
| `profiles`, `profile_get`, `profile_range`, `profile_whole` | what is running, and each profile live, whole or for a time range |
| `probe_start`, `probe_stop`, `probe_list`, `probe_get` | function probes |
| `processes` | the latest frame of every process |
| `user_leave(user)` | a front end went away: it is dropped from every profile, and a profile nobody is left watching stops |

A `UserId` says who started each job, so one session can serve several windows or browser
tabs.

**Around a profile:**

| | |
|---|---|
| `runs.Store` | saved runs: `open`, `save`, `list`, `info`, `profile`, `relabel`, `delete`. Each run is two files: a small `<id>.meta.json` for listing, and `<id>.profile.json`. Writes go to a temporary name and are renamed |
| `runs.sudo_owner` | under `sudo`, the user who ran it: their home holds the runs, and they own the files |
| `compact` | a profile packed for the wire and for saved runs: each string once, frames as indexes |

Saved runs live in `$NUSKU_RUNS_DIR`, else `$XDG_DATA_HOME/nusku/runs`, else
`~/.local/share/nusku/runs`. The CLI and the app share them.

## Architecture

| File | |
|---|---|
| `client.zig` | the facade: the only file front ends import |
| `local.zig` | the server and its agents in this process, for the one-shot calls |
| `session.zig` | the long-lived server and its jobs, with who started each |
| `profile_cache.zig` | a live profile kept up to date one report at a time, instead of rebuilt each time it is asked for |
| `probe_list.zig` | a session's function probes and how each ended |
| `runs.zig` | saved runs on disk |
| `compact.zig` | the packed profile format |

## Tests

```sh
zig build test                    # from the repository's root
sudo zig build test -Dapp=false   # with the session tests that profile a real process
```
