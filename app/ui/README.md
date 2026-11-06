# Nusku UI

React + TypeScript + Vite, Tailwind and shadcn (Base UI). Built and embedded into the app by
`zig build` (see `../README.md`). Runs on sample data for now.

## Layout

```
src/
  lib/profile/types.ts     the data model, mirroring the server (Frame, Stack, Profile, Session)
  lib/profile/analyze.ts   stacks -> top functions, call tree, callers/callees, folded export
  metrics/registry.ts      every metric (cpu, offcpu, mem, io, net, locks, sched): unit, icon, views
  data/source.ts           the DataSource interface: all the UI knows about where data comes from
  data/hooks.ts            useSessions, useSession, useProfile, useProcesses
  data/mock/               the sample data: fake programs, live sessions that grow
  features/profile/        the views: FlameGraph, TopFunctions, CallTree, Timeline, FunctionDetails
  features/profile/views.tsx   the view registry
  features/sessions/       session list and session page
  features/processes/      process list and the start dialog
  components/ui/           shadcn components (generated)
```

## Extending

- **A new metric** (say `mem`): in `metrics/registry.ts` set its `status` to `'ready'`, and make the
  data source return its profile. Its stacks carry bytes instead of samples; the flame graph,
  top functions and call tree work unchanged, and numbers format by the metric's `unit`.
- **A new view** for a metric: a component taking `ViewProps`, added to `features/profile/views.tsx`
  and named in the metric's `views`.
- **The real backend**: a second `DataSource` on top of `lib/backend.ts`, chosen in `main.tsx`.

## Commands

- `npm run dev`: Vite on 127.0.0.1:5173 (works in a plain browser too, on sample data).
- `npm run lint`, `npm run typecheck`.
