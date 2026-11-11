---
date: 2026-11-12
---

# Ep31: The CLI Catches Up

*For a few episodes the app got everything first: lines, inlined frames, quality, launching,
time ranges, many profiles at once. This episode brings `nusku prof` level with it, and adds
`nusku watch`: one session in the terminal that profiles several processes and lets you look
at any of them.*

1. [`nusku prof`, aligned](#1-nusku-prof-aligned)
2. [Lines and inlined frames in text](#2-lines-and-inlined-frames-in-text)
3. [Launching, the same way as the app](#3-launching-the-same-way-as-the-app)
4. [Part of a run: --from and --to](#4-part-of-a-run---from-and---to)
5. [`nusku watch`](#5-nusku-watch)
6. [How watch is built](#6-how-watch-is-built)
7. [What is left](#7-what-is-left)

## 1. `nusku prof`, aligned

| | Before | Now |
|---|---|---|
| Top functions | name, module | + hottest `file:line`, + `inlined` when it ran mostly inlined |
| Call tree | function frames | + inlined frames, marked |
| After the tree | — | a **Quality** section (Ep30) |
| `--exec` | `std.process.spawn`, killed at the end | the app's launcher, `--keep-running` |
| Part of a run | — | `--from <s>` and `--to <s>` |

The header, the live view and the folded output for other tools are unchanged.

## 2. Lines and inlined frames in text

```
  Top functions  by self time, 12 of 12 that ran
    SELF               TOTAL              FUNCTION
     46.4% ████▋        49.8% ████▉       main.hot_leaf  zig-app  main.zig:20
     30.3% ███          30.3% ███         main.recurse  zig-app  main.zig:36
      9.7% ▉            11.4% █▏          sort.block.mergeInto__anon_3556  zig-app  block.zig:1015  inlined
```

The line shown is the one the function spent most of its **own** time on (ties broken by
total time), which is where to look first. It is only computed for the final report: the live
view, redrawn every second, does not pay for it.

A function is tagged `inlined` when at least half of its time was spent inlined into a caller.
In the call tree, every inlined frame is tagged, so a chain like
`start.callMainWithArgs inlined → start.callMain inlined → main.main` reads as what it is: one
real call with two inlined steps.

## 3. Launching, the same way as the app

`--exec` used to spawn with the standard library and kill the child on the way out. It now uses
`client/launch.zig` (Ep30), so the CLI and the app behave the same:

- The program starts **stopped** and is resumed once the agent is attached.
- Its input is empty and its output is discarded, so it cannot garble the live view.
- Errors are sentences: `cannot launch no-such-program: no such program (give a path, or a name
  on PATH)`.
- With **`--keep-running`**, it is left running when profiling ends. It runs in its own
  session, so the Ctrl-C that stops Nusku does not reach it. `--keep-running` without `--exec`
  is a usage error.
- Without it, a program still running at the end is ended (`SIGCONT`, then `SIGTERM`); one that
  already exited is left alone.

## 4. Part of a run: `--from` and `--to`

```
nusku prof --pid 1234 --duration 30 --from 10 --to 20
```

profiles for 30 seconds and shows seconds 10 to 20 of it, counted from the first report. It
is the CLI's version of selecting a range on the app's timeline, and it uses the same rule: a
window belongs to the range when its **midpoint** is inside it. The header says which part it
shows (`· seconds 10 to 20`), and a range with no report in it is an error, not an empty
profile.

## 5. `nusku watch`

`nusku prof` is one process, one profile, then exit. `nusku watch` is a session that stays:

```
$ sudo nusku watch
nusku watch: type help for the commands, quit to end.
nusku> prof 395277 5
profile 1: zig-app [pid 395277]
nusku> launch ./testing/out/c-app 60
profile 2: c-app launched, stopped when profiling ends
nusku> watch
  ID       PID  PROGRAM               STATE              ELAPSED    SAMPLES
   1    395277  zig-app               live                   3.8s        297
   2    395317  c-app                 live                   2.7s        191
nusku> watch 2
  … the live top functions of c-app, redrawn every second; Enter goes back …
nusku> watch 1
  … profile 1 has ended: its full report, with the call tree and quality …
nusku> stop 2
profile 2: stopped
nusku> quit
```

| Command | Does |
|---|---|
| `prof <pid> [seconds]` | Profile a running process, until stopped or for that long |
| `launch [--keep] <program> [args]` | Start a program and profile it from its start |
| `watch` | List the profiles: id, pid, program, state, elapsed, samples |
| `watch <id>` | Watch one live; Enter or Ctrl-C goes back to the prompt. An ended one prints its full report |
| `stop <id>` | Stop profiling it. The process is never touched, unless it was launched without `--keep` |
| `help`, `quit` | |

Profiles keep running in the background while you type, and an ended profile stays readable
until the session ends.

## 6. How watch is built

`watch` is a thin shell over **`client.Session`**, the same session the app uses (Ep26). That
gives it, for free:

- many profiles at once, each a job on the session's controller;
- the profile cache (Ep27): `watch <id>` asks `profile_get` once a second and only changed
  stacks are rebuilt;
- launched programs, their ending and their reaping;
- the same errors, turned into sentences: `cannot: no profile with that id: watch lists them`.

Two terminal details took more care than the rest:

- **Waiting for Enter while redrawing.** The live view must redraw every second and also notice
  Enter. Standard input is read straight from the file descriptor through a small line buffer,
  and the live loop `poll`s it with a one-second timeout: a line ends the view, a timeout
  redraws.
- **Ctrl-C means "back", not "exit".** In `nusku prof`, Ctrl-C stops the run. In `watch`, it
  ends a live view and returns to the prompt, and at the prompt it ends the session. The signal
  handler only sets a flag, and each loop checks it.

Logs at `info` would land in the middle of the prompt, so `watch` only shows warnings unless
`--log-level` or `-v` asks for more.

The session lives inside the `nusku watch` process: `quit` (or Ctrl-D) ends every profile it
started, and the programs it launched unless they were given `--keep`.

## 7. What is left

- **Sharing with the app.** `watch` and the app each have their own session in their own
  process, so `watch` does not see the app's profiles. A server of its own, reached over a
  socket (Ep26), is what would join them.
- **A flame graph in the terminal** is not planned: the call tree is the terminal's version,
  and `--folded` feeds the classic flame graph tools.
- **`watch <id> --from/--to`**, to look at part of a profile that is still running.
