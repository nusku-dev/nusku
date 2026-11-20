# Nusku app and web

One UI, two programs, both built by `zig build` at the repository's root:

- `nusku-app`: a desktop window (WebUI: the system browser in app mode). Nothing to open: it
  talks to its window over a private localhost port it picks itself.
- `nusku-web`: the same UI for any browser, on port 80 (`--port N` or `NUSKU_PORT` for
  another, `--public` to listen beyond this machine, with no password: only on a trusted network).

Each is one binary: the UI is built by Vite and embedded at compile time. Both are clients of
nusku next to `nusku-cli`, reaching the same server through the `client` module at the
repository's root. What the CLI can ask, the app asks the same way.

## What it shows

| Page | |
|---|---|
| Processes | every process with its CPU and memory, the machine's CPU over the last minute; profile any process, or launch a program under nusku |
| Sessions | the profiles running and ended; each one live: the top functions, a flame graph and the call tree, coloured by self time, for the whole run or a time range picked on its CPU chart |
| Saved runs | profiles kept with a label and a note; open one, rename it, export its folded stacks, or compare two |
| Compare | two runs, or two series of repeated runs, function by function: what got faster or slower, and what is only noise |
| Probes | every call of one function: calls a second, mean, p50, p99 and slowest, and a histogram of the times |

## Public API: the bindings

The UI calls Zig through WebUI bindings. Each answers JSON, or `{"error": "<name>"}`:

| Binding | File | |
|---|---|---|
| `get_processes` | `processes.zig` | the latest frame of every process |
| `profile_start`, `profile_launch`, `profile_stop` | `profile.zig` | profile a process, or launch a program and profile it |
| `profile_stream` | `profile.zig` | the profiles, running and ended |
| `profile_get`, `profile_range` | `profile.zig` | one profile live (only what changed since the last ask), or for a time range |
| `runs_save`, `runs_list`, `runs_get`, `runs_relabel`, `runs_delete` | `runs.zig` | saved runs |
| `probe_start`, `probe_stop`, `probe_list`, `probe_get` | `probes.zig` | function probes |

All of them go to one `client.Session` (`session.zig`), the same API `nusku-cli watch` uses.
`ui/src/lib/backend.ts` has a typed wrapper for each.

## Layout

```
../build.zig       builds both (and nusku-cli); -Ddev switch; runs Vite and embeds its output
tools/embed.zig    build-time: Vite output -> assets.zig (one HTTP response per file)
src/main.zig       window (nusku-app) or server (nusku-web); dev (Vite URL) or embedded files
src/static.zig     serves the embedded files; 404 for anything unknown, never the disk
src/api/           the bindings, one file per area, and the session they share
ui/src/pages/      one per page above
ui/src/hooks/      what the pages read: each polls a binding (use-profiles, use-runs, ...)
ui/src/components/ the flame graph, call tree, charts, dialogs; ui/ holds the base widgets
ui/src/lib/        backend.ts, the router, and the profile and comparison maths
```

## Commands

From the repository's root (the first build runs `npm ci` in `ui/` if needed):

| What | How |
| --- | --- |
| Build all three | `zig build -Doptimize=ReleaseSafe` (then `zig-out/bin/`) |
| Run the app | `zig-out/bin/nusku-app` |
| Run the web UI | `sudo zig-out/bin/nusku-web`, or `zig-out/bin/nusku-web --port 8080` |
| Develop with hot reload | `cd app/ui && npm run dev`, and `zig build -Ddev && zig-out/bin/nusku-app` |
| Tests | `zig build test` |
| UI checks | `cd app/ui && npm run lint && npm run typecheck` |

In dev mode the backend listens on port 9000 and Vite (5173) proxies `/webui.js` to it.
Both ports are fixed in `build.zig`, `src/main.zig` and `ui/vite.config.ts`.
A release build picks a free port.

## Adding a call from the UI to Zig

1. `src/api/<name>.zig`: write the function (see `processes.zig`), and bind it in
   `src/api/api.zig`. It asks the `client` module, under a lock (the client runs one call at a
   time), and returns JSON with `returnString`; a failure returns `{"error": "<name>"}`.
2. `ui/src/lib/backend.ts`: add a typed wrapper to `backend`.
3. A hook in `ui/src/hooks/` that calls it, like `use-machine.ts`; pages use the hook.

## Root

The processes list needs nothing. Profiling needs root, or these capabilities on the binary:

```sh
sudo setcap cap_bpf,cap_perfmon,cap_syslog,cap_checkpoint_restore+ep zig-out/bin/nusku-app
sudo setcap cap_bpf,cap_perfmon,cap_syslog,cap_checkpoint_restore,cap_net_bind_service+ep \
    zig-out/bin/nusku-web
```

`cap_bpf` and `cap_perfmon` sample, `cap_syslog` names kernel frames, and
`cap_checkpoint_restore` names a program rebuilt while it runs (its file is deleted, and only
`/proc/<pid>/map_files/` still reaches it). A rebuild of the app drops the capabilities: run
`setcap` again. Function probes ("Track calls") need more: the kernel opens uprobes only
with `cap_sys_admin`, which is close to root, so it is left out of the line above; add it
only if you accept that. A browser window should not run as root: later, profiles will come from a
nusku server running with those rights. `nusku-web` may run as root (the browser is elsewhere);
saved runs then go to the home of the user behind `sudo`, as with `sudo nusku-cli prof --save`.

Ended by a signal (Ctrl-C, `kill`, logout), `nusku-app` closes its windows before it exits.

WebUI runs each call on its own thread, so lock anything the calls share.
