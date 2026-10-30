---
date: 2026-10-31
---

# Ep12: The Bugs the Tests Found

Ep10 and Ep11 were about design. This one is about bugs: some found by reading the code
carefully, and two that only showed up when the tests ran as root against a real kernel. The
last one is my favourite, because the test was right and the profiler was wrong.

## 1. Closing one file descriptor twice

The unwind rows map was owned by two structs at once. `Maps` (the list of every map of the
program) had it, and `TableMaps` (the writer of the unwind tables) got a copy of the same file
descriptor. Both closed it on shutdown.

```
 TableMaps.deinit  -> close(fd 7)    ok
 OnCpu.deinit      -> close(fd 7)    closes... whatever got fd 7 in between
```

In a program with one thread this is harmless: `close` fails with `EBADF`. In a program with
threads, another thread may have opened a file and received the number 7 between the two
closes. The second close then closes **its** file. That is a silent, random bug in someone
else's code.

The fix is ownership: each map has exactly one owner, which creates it and closes it. The unwind
maps belong to `unwind/tables.zig`. The CPU program only receives their numbers, to patch into
its code, and never closes them.

Map creation had a related leak: the maps were created in a loop, with an `errdefer` inside the
loop body. An `errdefer` in a loop body only covers its own round, so if the fifth map failed,
the first four were never closed. Now there is one `errdefer` that counts what was created:

```zig
var created: u32 = 0;
errdefer for (maps.values[0..created]) |*map| map.deinit();
for (&maps.values, 0..) |*map, index| {
    map.* = try Map.create(@tagName(@as(MapName, @enumFromInt(index))), spec);
    created += 1;
}
```

## 2. Writing 3 MiB every second for nothing

All unwind rows live in one array map value of 3 MiB (Ep9 explains why). When the target maps
a new library, its rows are added and the value is written again.

The function that did this checked whether there was anything new like this:

```zig
if (from >= set.modules.len) return;    // modules.len is the capacity: 256
```

`modules.len` is the size of the array, not the number of modules in it. With 5 modules
loaded, `5 >= 256` is false, so it went on, every report: it copied the 3 MiB, wrote it to the
kernel, and wrote 251 empty module descriptors. With a 1 s interval, that is 3 MiB of memory
traffic and 252 system calls per second, to change nothing.

Now the count of modules is compared with the count already written, and most reports write
nothing at all:

```zig
if (tables.modules_written == set.modules_count) return; // Nothing new: the usual case.
```

The fix also removed a 3 MiB copy (`image`) of rows the table set already had. The map is now
written straight from the set.

## 3. A walk that could continue on someone else's stack

A stack walk takes several runs of the BPF program (4 frames per run, then a tail call). The
state between runs lives in a per-CPU map, with a flag `walk_in_progress`.

If a run ever returned early with the flag still set, the **next** sample on that CPU, maybe a
different thread, would see `walk_in_progress = 1` and continue the old walk with the old
registers. The result would be a stack made of two different threads.

Today no path does that: every path that starts a walk finishes it or tail-calls. But "today no
path does that" is the kind of promise that breaks quietly. So the walk now remembers its task:

```zig
if (state.walk_in_progress != 0) {
    if (state.walk_pid_tgid != pid_tgid) {
        // Count it, and never continue it with this task's stack.
        state.walks_abandoned += 1;
        state.walk_in_progress = 0;
    }
}
```

`walks_abandoned` should stay 0 forever. If it ever is not, the window reports it, and the bug
is visible instead of mixing stacks.

## 4. The test that profiled the clock

Now the root tests. One of them burns the CPU for 300 ms and checks the profile. I had added a
check: "most stacks must be complete". It failed:

```
session: 29 samples in 300 ms, deepest user stack 10 frames
FAIL: complete * 2 >= first_samples
walks=1200 kernel=725 ...
```

725 of 1200 samples were taken in kernel mode, while the test was supposedly only burning CPU
in its own code. The burn loop looked like this:

```zig
while (timer.monotonic_ns() < deadline_ns) counter +%= 1;
```

`monotonic_ns` calls `clock_gettime`, and Zig calls it through the **vDSO**, a small piece of
kernel code mapped into every process so that reading the clock does not need a system call.
The loop did one addition and then a clock read, so nearly all its time was in the clock, not
in the loop.

The vDSO has no file on disk the agent can read, so it gets no unwind table. A sample inside
it can only fall back to frame pointers, and the vDSO does not keep them. So those stacks
stopped right there.

The fix was in the test: read the clock once every 65,536 rounds. The profiler then sees the
loop, which is what the test wanted to profile.

But the lesson is about real programs: **a program that reads the clock in a hot path loses the
callers of those samples.** Unwinding through the vDSO (by reading its `.eh_frame` from memory)
is the next on-CPU accuracy step.

## 5. The test was right, the profiler was wrong

After that fix, the same test failed again, more interestingly:

```
deepest user stack 7 frames
  stop no_function_info: 29 samples
```

Every single stack stopped with the same reason. They were 7 frames deep, so the unwinder was
clearly working. Where did they all stop?

The test binary is a static Zig program with musl. Its stack, from the bottom:

```
 _start                    <- no .eh_frame entry, sets rbp = 0
 _start_c                  (musl)
 __libc_start_main ...
 main ... test function ... cpu_burn
```

Checking the binary confirmed it:

```
$ objdump -d agent-tests
00000000014961d0 <_start>:
 14961d0:  xor    %rbp,%rbp          <- rbp = 0
 14961d3:  mov    %rsp,%rdi
 ...
 14961e1:  call   14961e6 <_start_c>

_start: NOT covered by any of the 5145 FDEs
```

So every walk climbed correctly all the way up to `_start`. There it found an address with no
table row, and `rbp` equal to 0. The program said: "no row, no frame pointer, I cannot go on",
and called it `no_function_info`, an incomplete stack.

But it was complete. The x86-64 System V ABI says it directly: the content of `rbp` at process
start is unspecified, but **user code should mark the deepest stack frame by setting the frame
pointer to zero**. That is exactly what `_start` does in its first instruction.

The frame-pointer path of the program already knew this rule (`rbp == 0` means `end`). Only the
"no row" path did not. The fix removed the special case, so a missing row always falls back to
frame pointers, and the frame-pointer path ends the walk:

```zig
// No row: follow the frame pointer. An rbp of 0 here is the end of the stack, not a missing
// table: the x86-64 ABI has the outermost frame zero rbp, and _start, which does it, often
// has no FDE (Zig's and musl's do not). frame_pointer_unwind ends the walk on it.
caller = frame_pointer_unwind(sp, bp);
```

The walk stops at the same frame as before, so no frame was gained or lost. But the label is
now right, and that matters: before the fix, every complete stack of a statically linked Zig or
musl program was reported as incomplete (in this test, all 29 of 29). Anyone reading that profile would have
distrusted it, or gone looking for a bug in their own binary that was not there.

The run after the fix:

```
walks=1200 kernel=2 sent=107 repeated=1093 dropped=0 counts_full=0
session: 29 samples in 300 ms, deepest user stack 7 frames
  stop end: 29 samples
All 87 tests passed.
```

`StopReason.no_function_info` is no longer written by the program, but its number (4) stays
taken. The numbers travel to the server, so they must never change meaning.

## 6. What I take from this

- **Ownership fixes whole classes of bugs.** The double close was not a typo. It came from two
  structs believing they owned the same thing. Give each resource one owner and the question
  disappears.
- **Compare counts, not capacities.** `len` of a preallocated array is how much fits, not how
  much is in it. TigerStyle's naming (`modules_count` next to `modules_max`) makes the
  difference visible in the code.
- **Tests should profile what they think they profile.** The burn loop measured the clock. A
  test that checks the shape of its own profile (where the walks stop, not just how many
  samples) found it in one run.
- **A test that fails on a surprising check is worth reading closely.** The "most stacks are
  complete" check looked too strict at first. It was right, and it found a real accuracy bug in
  the kernel program.

## 7. Summary

| Bug | Found by | Fix |
|---|---|---|
| rows map fd closed twice | reading | one owner per map |
| maps leaked if one creation failed | reading | one counted `errdefer` |
| 3 MiB rewritten every report | reading | compare counts, not capacity |
| a walk could continue on another task | reading | remember `pid_tgid`, count `walks_abandoned` |
| the test profiled the vDSO clock | root test | read the clock every 65,536 rounds |
| complete stacks reported as incomplete | root test | `rbp == 0` without a row is `end` |

Next: unwinding through the vDSO, so programs that read the clock in their hot paths keep
their callers.
