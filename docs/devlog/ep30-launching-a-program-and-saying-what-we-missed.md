---
date: 2026-11-12
---

# Ep30: Launching a Program, and Saying What We Missed

*Two features that make a profile something you can act on. Launching: profile a program from
its first instruction instead of racing to attach. Quality: a profile that tells you where it
is blind, instead of letting you trust a picture with holes in it.*

1. [Attaching is too late](#1-attaching-is-too-late)
2. [Starting a program stopped](#2-starting-a-program-stopped)
3. [Ending it, or not](#3-ending-it-or-not)
4. [Never touching an attached process](#4-never-touching-an-attached-process)
5. [In the app](#5-in-the-app)
6. [A profile that says what it could not see](#6-a-profile-that-says-what-it-could-not-see)
7. [What is left](#7-what-is-left)

## 1. Attaching is too late

Profiling a running pid works for servers and apps. For a command that runs for two seconds,
by the time you have its pid it is half done, and its startup (often the slow part) is gone.
The answer is to start it ourselves, stopped, attach, and only then let it run.

## 2. Starting a program stopped

`client/launch.zig` starts a program in five steps:

```
parent                                   child
──────                                   ─────
pipe2(CLOEXEC)
fork() ───────────────────────────────▶  setsid()
                                         clear the signal mask
                                         stdin, stdout, stderr → /dev/null
                                         execve(path, argv, environ)
                                           ├─ ok: the pipe closes by itself (CLOEXEC)
                                           └─ fails: write errno to the pipe, exit(127)
read(pipe)
  ├─ 4 bytes: an errno → ProgramNotFound / NotExecutable / LaunchFailed
  └─ EOF: exec happened → kill(SIGSTOP), waitpid(WUNTRACED)
           ├─ stopped → its pid
           └─ exited  → ExitedAtOnce
```

Things worth knowing about it:

- **The close-on-exec pipe** is the standard trick to tell "exec failed" from "the program
  started": a successful `execve` closes the write end, a failed one writes `errno` through
  it. That is how `nusku prof --exec no-such-program` can say *no such program* instead of a
  profile of a process that died at once.
- **Only async-signal-safe calls after `fork`.** The child runs raw syscalls and nothing that
  allocates or locks: the parent has threads, and a lock held by one of them at the moment of
  `fork` would never be released in the child.
- **`setsid`** puts the program in its own session, so a Ctrl-C in your terminal goes to Nusku,
  not to a program you asked to keep running.
- **The program reads nothing and writes nowhere.** A profiled program printing into the app's
  terminal, or the CLI's live view, would garble it.
- `PATH` is searched for a name without a slash, as a shell would.

Then the profile starts on that pid with `continue_target`: once the agent is attached, the
session sends `SIGCONT`, and the very first instructions of the program are sampled.

## 3. Ending it, or not

When its profiling ends, a launched program is either **ended** or **kept running**, the
caller's choice (`end_program` in the session, "Stop the program" / "Leave it running" in the
app, `--keep-running` in the CLI).

Ending is `SIGCONT` then `SIGTERM`: a stopped process acts on no signal but `SIGKILL`, so it
has to be woken first to receive the polite one.

The session is the parent of every program it launched, so it must **reap** them or they stay
as zombies. It keeps their pids and collects the ones that ended with a non-blocking
`waitpid` whenever it looks at its profiles, and once more when it shuts down.

## 4. Never touching an attached process

A process you attached to by pid is never signalled, never stopped, never ended. Stopping a
profile detaches the eBPF programs and nothing else. This was a bug at first: the first
version of stop in the session killed what it had started, and attached and launched
processes went through the same path. They are now told apart by `launched`, and the session
test checks both.

## 5. In the app

The same start dialog serves both:

- **A running process**: opened from its row in the processes table.
- **A program**: opened from the **Launch program** button on the processes page. It takes a
  path or a name on `PATH`, its arguments (split like a shell: quoted text stays together),
  and what to do with it when profiling ends.

Both take how often to report and for how long (until stopped, or 10 s to 5 minutes).

Below the form it shows the equivalent CLI command, so what you set up in the app can be
copied into a script.

## 6. A profile that says what it could not see

A flame graph looks equally sure of itself whether it saw everything or half. Three things
make a profile wrong without making it look wrong:

| Problem | What you would see | What it really means |
|---|---|---|
| **Cut-short stacks** | A function with no callers, floating at the root | The unwinder stopped: the time is real, the call path is not |
| **Unnamed code** | Gray `[libfoo.so]` boxes | The time is real, but you cannot tell where |
| **Lost samples** | Nothing | The kernel dropped samples: everything is a bit off |

So every profile now carries a **quality** summary, computed alongside it (in the page's
engine it is updated incrementally, like everything else, Ep27):

- the share of samples whose stack was **cut short** (`complete == false`),
- the share whose leaf has **no name**,
- **lost** samples and **rejected** windows,
- and, per binary, how many samples ran in it **with no name** or **with no line info**, with
  the fix: install its debug package, set `DEBUGINFOD_URLS`, or build it with `-g`.

The app shows a short verdict on the session page (good when under 5% is cut short or unnamed,
under 1% lost, nothing rejected), and the details on demand. The CLI prints the same as a
`Quality` section (Ep31):

```
  Quality
    ✓ every stack is whole, out to the program's start
    ! 5.7% of samples ran in code with no name
    ✓ no samples lost
    libc.so.6  no names on 5.7% of samples: install its debug package (-dbgsym), ...
```

That last line is how the bug in Ep32 was found: a profile that said "libc has no names" on a
machine where libc certainly does.

`[vdso]` is left out of the per-binary list: it is the kernel's page in every process, and
there is no debug package to install for it.

## 7. What is left

- **The program's output.** It goes to `/dev/null` today. Keeping the last few kilobytes and
  showing them when a program exits at once would explain *why* it exited.
- **An environment and a working directory** for the launched program, in the dialog.
- **Running as another user.** Under `sudo`, a launched program runs as root. Dropping to the
  invoking user would be safer.
