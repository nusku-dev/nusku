---
date: 2026-11-21
---

# Ep32: The Gray libc

_A bug report that looked like "names disappear after a while", and was really "names were
never asked for twice". How it was found in a running process with gdb, and why the fix made
Nusku do far less work, not more._

1. [The report](#1-the-report)
2. [Reading the server's mind with gdb](#2-reading-the-servers-mind-with-gdb)
3. [The cause](#3-the-cause)
4. [The fix: only what runs, and later instead of never](#4-the-fix-only-what-runs-and-later-instead-of-never)
5. [The protocol change](#5-the-protocol-change)
6. [Before and after](#6-before-and-after)
7. [What it taught](#7-what-it-taught)

## 1. The report

After leaving the app profiling itself for a while, more and more of the flame graph was gray
boxes labelled `[libc.so.6]`, and the quality summary (Ep30) said:

> 5.7% of samples ran in code with no name

libc has names. It always has: its symbols come from its own symbol table and its debug file.
The first guess was eviction: the server keeps symbol tables under a 256 MiB budget and drops
the least recently used one to make room, and a dropped table is never sent again. That would
fit "after a while".

The guess was wrong, and the way to know was to look.

## 2. Reading the server's mind with gdb

The app was still running, so the first step was its own API. A browser tab on the app's
WebUI port can call the same functions the UI calls, and the profile showed something
sharper than the report: **every** libc frame was unnamed, in every window, including the
first second. Only libc. The app's own frames, `ld.so`, `libgcc` and the kernel were fine.

Then the server itself. gdb can attach to a running process and read globals without
stopping it for more than a moment. The session is a global in the app,
`api.session.current`, so:

```
(gdb) p 'api.session.current'.server.symbols.binaries.count
$1 = 67
(gdb) p 'api.session.current'.server.symbols.binaries.bytes_used
$2 = 226420011                       ← 216 MiB of the 256 MiB budget
(gdb) p 'api.session.current'.server.symbols.generation
$5 = 67                              ← one per table kept or failed: none evicted
(gdb) p 'api.session.current'.server.symbols.builds_failed
$6 = 0
```

and a loop over the 67 entries printing each build ID. libc's (`a4a7992a…`) was not among
them. 67 tables, 67 generations, no failures: **nothing was evicted, and libc was never built
at all.**

## 3. The cause

The app maps about **170 libraries**: WebKit, GTK, GStreamer, curl, and everything they pull in.
The agent offered every one of them to the server when profiling started, one after another:

1. The agent offers a binary; the server says "wanted"; the binary is uploaded. Uploads are
   fast, in-process.
2. The builder thread turns uploads into tables. Building is slow: each stripped library
   waits on a debuginfod download first (Ep28), up to 15 seconds.
3. The build queue holds **32**. An upload that finished while it was full was dropped, with
   one warning in the log.
4. The agent offers each binary **once per run**. Nothing ever asked for it again.

About 100 libraries were dropped that way, and libc was one of them. It only looked like
something that happened "after a while" because libc's share of the samples grew as the app
did more work.

There was a second cost hiding in the same numbers: 216 MiB of tables and about 170 MB of
downloads, for libraries of which only **five** ever appeared in a sample.

## 4. The fix: only what runs, and later instead of never

**Offer only what was sampled.** After each report, the agent maps every stack address to its
region (a binary search: the regions are sorted and do not overlap) and offers only the
binaries code actually ran in. A return address is looked up one byte back, as naming does,
so a call at the very end of a function counts for the right file.

**"Later" is not "no".** The server now has three answers to an offer:

| Answer     | When                                                  | The agent                           |
| ---------- | ----------------------------------------------------- | ----------------------------------- |
| `wanted`   | not known, and the builder keeps up                   | sends it                            |
| `unwanted` | already known, on its way, or refused for good        | forgets it                          |
| `later`    | the uploads and builds waiting reach the queue's size | offers it again with a later report |

**Ask again for what was lost.** A binary can still be lost after it was wanted: the upload
budget is full, the queue fills between the offer and the upload, or its table is evicted
months later. The server remembers those build IDs. When a report shows a region with one
of them, its answer to that report is `resend`, and the agent forgets what it offered,
except what is still queued, so the binaries it samples are offered again. The ones the
server has are declined in one round trip; the lost one is sent.

**Old samples heal too.** Names are applied when a profile is read, and the profile cache
resets when the server's `names_generation` changes (Ep27). So once libc's table is built,
the gray frames from before turn into names as well, without restarting anything.

## 5. The protocol change

```zig
/// To an offer: send it, it is not needed, or ask again later. To a report: `resend` asks
/// the agent to offer again the binaries it sampled, as one of them was lost.
pub const Answer = enum { none, wanted, unwanted, later, resend };
```

On the agent's side, the run grew two calls next to `binary_want`: `binary_later()` and
`binaries_resend()`. The controller's job loop maps answers to them. Everything else, the
transfer itself, the chunking and the kernel's symbols, is unchanged.

The tests that pin it:

- only binaries that code was sampled in are queued, with the leaf and return-address rules;
- a binary taken `later` is offered again with the next report, and one declined is not;
- after `resend`, each sampled binary is offered again exactly once;
- a busy server answers `later`, and `wanted` again as soon as there is room;
- a binary lost while the server was busy, or evicted while still running, is asked for again
  once;
- a run that stops finishes its transfer, then offers what its last report sampled;
- a run that stops while the kernel is read waits for it a little, never long.

## 6. Before and after

Profiling the same `nusku-app` (154 mapped files at the time):

|                               | Before           | After                                              |
| ----------------------------- | ---------------- | -------------------------------------------------- |
| Binaries offered and uploaded | ~170             | only those sampled                                 |
| Tables built                  | 67, libc dropped | 2 (libc and the kernel), none dropped              |
| Memory for tables             | 216 MiB          | 19 MiB                                             |
| libc                          | unnamed          | `clock_nanosleep  libc.so.6  clock_nanosleep.c:78` |

Names now arrive after the first report, about a second in, since an offer waits for a
sample. On a profile you watch for minutes, nobody notices.

**And then a regression, caught by checking the devlog.** Writing "a short run still gets
every name" made me check it, and it was false: `nusku prof --exec sha256sum` on a big file
(about a second) came back with _everything_ unnamed, the kernel included. A run that short
has one report, its last, and stopping the agent cleared the queue of binaries to offer:
exactly the ones that report had just sampled. Before this change the queue was filled at
the start of the run, so it did not show.

Stopping now finishes what is queued: the transfer in flight, then an offer for each binary
the last report sampled. The kernel needed one more step. Reading `/proc/kallsyms` (200 000
symbols) takes the agent about 3.5 s from the start of a run, so a run stopped earlier
used to lose the kernel's names every time, long before this bug. A stopping run now waits
for that read, at most 3 seconds. A run that is past its first seconds has finished the read
and does not wait at all; one stopped earlier waits once, and the CLI was going to wait for
its symbol tables to build anyway.

```
  nusku  sha256sum [pid 212279] · 4.3 s · 102 samples at 99 Hz · process exited
     93.1% █████████▎       –             [libcrypto.so.3]
      1.9% ▏             1.9% ▏           rep_movs_alternative  [kernel]
      0.9%               5.8% ▌           vfs_read  [kernel]
```

The kernel is named again. `libcrypto` stays gray, and that one is real: its table was built
(5 363 functions), but its SHA code is assembly with no exported symbol, and the CLI cannot
download its debug file. The quality section says so, and says what to install.

## 7. What it taught

- **A quality line found it.** Without "5.7% of samples ran in code with no name", gray boxes
  in a flame graph are easy to ignore. Saying what the profile cannot see (Ep30) earned its
  keep on the first real bug.
- **Look before guessing.** Eviction was a good story that matched the symptom. Thirty seconds
  in gdb showed `generation == count`, and the story was over.
- **Every "drop" needs a way back.** A queue that drops is fine; a protocol that never asks
  again turns a moment of being busy into a permanent loss. The fix was less about the queue
  than about giving every refusal a path to "try again".
- **Doing less was the fix.** The bug came from work nobody needed: tables for libraries that
  never ran. Offering only what was sampled removed the pressure that caused the drops, and
  most of the memory and network with it.
- **Write the devlog, then check it.** The short-run regression was found by testing a
  sentence in this episode before publishing it.
- **Deleted binaries came next, and are fixed.** While checking the fix, the app's own frames
  were unnamed, because rebuilding it had replaced its file on disk. The agent now reads such a
  binary through `/proc/<pid>/map_files/` (root, or `CAP_CHECKPOINT_RESTORE`), and opens a
  file by its path only while the path still names the mapped inode.
