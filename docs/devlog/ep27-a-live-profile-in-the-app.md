---
date: 2026-11-12
---

# Ep27: A Live Profile in the App

*Ep26 ended with the app able to list processes but not profile them. This episode is the
profile itself in the app: the views, and the work it took to keep a profile live once a
second without burning the CPU it is measuring.*

The first version was the obvious one: once a second, ask the session for the whole profile,
send it to the page as JSON, rebuild the flame graph from scratch. It worked, and on a real
program it cost **65% of a CPU** in the app, the page took **0.8 to 1.7 s** to redraw, and
every answer was **435 KB**. A profiler that loads the machine like that measures itself.

The fix came in three layers, one per place the work was being done again:

1. [What the page shows](#1-what-the-page-shows)
2. [The server side: a profile cache](#2-the-server-side-a-profile-cache)
3. [The wire: a compact profile](#3-the-wire-a-compact-profile)
4. [The page: an engine that takes changes](#4-the-page-an-engine-that-takes-changes)
5. [The timeline and a range](#5-the-timeline-and-a-range)
6. [Numbers](#6-numbers)
7. [Bugs on the way](#7-bugs-on-the-way)

## 1. What the page shows

A profile page (`pages/session.tsx`) has a timeline on top and a workspace below it:

| View | What it answers |
|---|---|
| **Flame graph** | Where the time goes, callers below, callees above. Click to zoom; the path back is a breadcrumb. Search highlights every match. |
| **Top functions** | Self and total time per function, sortable, searchable. |
| **Call tree** | The same tree as the flame graph, as rows you can open. |
| **Function details** | For the selected function: self vs total, its hottest source lines, and whether it was inlined (Ep29). |

The views share one selection: picking a function in the table selects it in the flame graph.
"Both" shows the flame graph and the table side by side.

**Colors.** A frame's color says what kind of code it is, not how hot it is: warm for the
program, blue for libraries, purple for the kernel, gray for code with no name. Inside a
family the exact shade comes from a hash of the name, so a function keeps its color between
refreshes. Width is time. This confused me once, looking at a very orange frame, so it is
written down here.

A **sessions** page lists every profile with its state, and a start dialog starts one, on a
running pid or by launching a program (Ep30).

## 2. The server side: a profile cache

The server keeps a profile as a ring of **windows**, one per agent report. Asking for the
whole profile merged every window and named every frame, every second, even though at most
one window was new.

`client/profile_cache.zig` keeps the merged profile and updates it one window at a time:

- Each window is queried once, at its **midpoint**, and its stacks are added to running
  totals. When the ring drops an old window, its stacks are subtracted.
- Each distinct stack (its frames, by name) gets a stable **id** the first time it is seen,
  and a **stamp**: the clock tick when its count last changed.
- Strings (function, file, module) are interned, so two frames compare by pointer.

A client asks with `profile_get(job, since)`, where `since` is the last clock it saw:

```
since == clock and nothing new     → unchanged         (no profile built at all)
since is current enough            → { clock, full: false, ids, stacks changed after since }
since is older than a reset        → { clock, full: true,  every stack }
```

A stack whose count fell to 0 is sent with 0, so the page removes it.

**When names change, everything resets.** Names arrive after the samples: a binary's symbol
table is built in the background. The server counts a `names_generation` that goes up every
time a table is kept or dropped. When it differs from the cache's, the cache drops its parts
and starts again, and the next answer is `full`. That is what makes frames that were addresses
turn into names on their own, without a restart.

## 3. The wire: a compact profile

The JSON was big because every frame repeated its strings. `app/src/api/compact.zig` sends a
string table and indexes into it:

```jsonc
{
  "strings": ["main.hot_leaf", "main.zig", "/bin/app", ...],
  "stacks": [
    { "d": 17, "n": 42, "c": true,          // id, samples, complete
      "f": [ { "a": "1162de0",              // address, as hex
               "k": false,                  // kernel
               "f": 0, "s": 1, "l": 20,     // function, file, line (-1 / 0: none)
               "m": 2, "i": false } ] }     // module, inlined
  ]
}
```

The address is hex text because it can be above 2^53, which a JavaScript number cannot hold
exactly (a "what is left" item from Ep26). Large counters go through `json.exact`, which
writes them as strings for the same reason.

## 4. The page: an engine that takes changes

Even with deltas, the page rebuilt the whole tree for every answer. `lib/profile/live.ts` keeps
an **engine**: the tree, the per-function totals and the quality counts, and applies a list of
changes, each a stack's `before` and `after`:

- A change walks its stack's path, adding or subtracting at each node, and marks the nodes it
  touched with the current **round**.
- Only marked nodes get a new view object; the rest keep theirs. React compares by identity,
  so untouched parts of the flame graph and table do not render again.
- Lines per function, and the stats, are copied on change, never mutated in place, for the
  same reason.
- Keys are short and numeric where they can be, and paths get stable ids, so a node keeps its
  identity between rounds.

`hooks/use-live-profile.ts` asks, applies, waits a second, asks again. A `full` answer resets
the engine. The project uses the React compiler, so the components themselves did not need
hand-written memoization.

## 5. The timeline and a range

The timeline draws samples per window. Dragging across it selects a range, and
`profile_range(job, from_ms, to_ms)` answers with that part of the run only (the same midpoint
rule decides which windows belong). The workspace then shows the range instead of the live
profile, until the selection is cleared. `hooks/use-range-profile.ts` does the asking.

## 6. Numbers

On the same program, with about 18 000 distinct stacks:

| | Before | After |
|---|---|---|
| App CPU with a live profile open | 65% | 9% |
| One answer | 435 KB, every second | 141 KB full; unchanged in 44 ms; ~3 KB/s streaming |
| Redraw on a new second | 0.8 – 1.7 s | 35 – 57 ms |
| First load of the whole profile | — | 1.1 – 1.4 s |

The first load is still the slowest thing on the page, and the next thing to look at if it
starts to hurt.

## 7. Bugs on the way

- **Every sample counted twice.** Windows can overlap at their edges, so a query for one
  window also caught its neighbour. Querying at the midpoint fixed it, and the test
  "cached equals whole" keeps it fixed: the cache must always equal a fresh merge.
- **Names that never came.** The cache was right but stale: it kept stacks built before the
  names. `names_generation` (section 2) fixed it.
- **A version mismatch after the run ended.** The summary used one naming mode and the stacks
  another, so a finished profile looked changed forever. The summary now uses the names the
  stacks were built with.
- **`pid 123 pid 123`.** A profile's label was built from the process name before the
  processes were known. It says "unknown" until they are, then updates.
- **A frozen browser tab** — mine. A benchmark loop in the page with a bad random generator
  never ended. Benchmarks of the engine now run in Node, not in the app.
