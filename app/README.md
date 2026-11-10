# Nusku app

A desktop window (WebUI: the system browser in app mode) whose page is a React + TypeScript UI.
A release build is one binary: the UI is built by Vite and embedded at compile time.

It is the second client of nusku, next to the CLI: both reach the same server through the
`client` module at the repository's root, which `build.zig.zon` brings in as the `nusku` path
dependency (with `shared`, the protocol's types). What the CLI can ask, the app asks the same way.

## Layout

```
build.zig          -Ddev switch; runs the Vite build and embeds its output
tools/embed.zig    build-time: Vite output -> assets.zig (one HTTP response per file)
src/main.zig       window setup; dev (Vite URL) or release (embedded files)
src/static.zig     serves the embedded files; 404 for anything unknown, never the disk
src/api/api.zig    binds the Zig functions the UI may call, one file each:
src/api/processes.zig  get_processes
ui/                the React app (Vite)
ui/src/lib/backend.ts   typed wrappers for every binding in src/api/api.zig
ui/src/hooks/           what the pages read: use-processes polls `backend.processes()`
```

## Commands

Once: `cd ui && npm install`

| What | How |
| --- | --- |
| Release build | `zig build` (then `zig-out/bin/nusku-app`) |
| Run release | `zig build run` |
| Develop with hot reload | `cd ui && npm run dev`, and in another terminal `zig build run -Ddev` |
| Tests | `zig build test` |
| UI checks | `cd ui && npm run lint && npm run typecheck` |

In dev mode the backend listens on port 9000 and Vite (5173) proxies `/webui.js` to it.
Both ports are fixed in `build.zig`, `src/main.zig` and `ui/vite.config.ts`.
A release build picks a free port.

## Adding a call from the UI to Zig

1. `src/api/<name>.zig`: write `get` (see `processes.zig`), and bind it in `src/api/api.zig`
   as `get_<name>`. It asks the `client` module, under a lock (the client runs one call at a
   time), and returns JSON with `returnString`; a failure returns `{"error": "<name>"}`.
2. `ui/src/lib/backend.ts`: add a typed wrapper to `backend`.
3. A hook in `ui/src/hooks/` that calls it, like `use-processes.ts`; pages use the hook.

## Root

The processes list needs nothing. Profiling will need root (CAP_BPF, CAP_PERFMON), and a
browser window should not run as root: profiles will come from a nusku server running with
those rights, through `client/remote.zig`. Until then, `sudo zig-out/bin/nusku-app` works for
development only.

WebUI runs each call on its own thread, so lock anything the calls share.
