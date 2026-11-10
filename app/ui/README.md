# Nusku UI

React + TypeScript + Vite. Built and embedded into the app by `zig build` (see `../README.md`).

- `src/lib/backend.ts`: the typed bridge to the Zig backend (`../src/api/api.zig`).
- `npm run dev`: Vite dev server on 127.0.0.1:5173, for `zig build run -Ddev`.
- `npm run lint`, `npm run typecheck`.
