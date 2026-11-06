# Nusku app

A desktop window (WebUI: the system browser in app mode) whose page is a React + TypeScript UI.
A release build is one binary: the UI is built by Vite and embedded at compile time.

## Layout

```
build.zig          -Ddev switch; runs the Vite build and embeds its output
tools/embed.zig    build-time: Vite output -> assets.zig (one HTTP response per file)
src/main.zig       window setup; dev (Vite URL) or release (embedded files)
src/static.zig     serves the embedded files; 404 for anything unknown, never the disk
src/api.zig        the Zig functions the UI may call (bindings)
ui/                the React app (Vite)
ui/src/lib/backend.ts   typed wrappers for every binding in src/api.zig
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

1. `src/api.zig`: write the function and bind it in `bind`. Return JSON with `returnString`.
2. `ui/src/lib/backend.ts`: add a typed wrapper to `backend`.
3. Use `backend.yourCall()` in components.

WebUI runs each call on its own thread, so lock anything the calls share.
