---
date: 2026-10-31
---

# Ep11: Counting Forever: Generations, Draining and the Frame Cache

At the end of Ep9 I wrote: "The counts only grow. The agent takes snapshots and uses the
difference between two snapshots as a time window. It never deletes anything."

That sounded clean. It was also a bug that breaks continuous profiling. This episode is about
why, and about the protocol that replaced it.

The short version:

> Every count carries a generation number. At each report the agent moves to a new generation,
> then takes the old generation's counts out of the kernel in two system calls. The map holds
> about one window, not the whole run.

## 1. The bug: a map that only grows

The counts map is a BPF hash map with a fixed size: `max_entries = 8192`. Every distinct stack
the target ever ran got a key, and keys were never deleted.

```
 minute 1:   1,200 distinct stacks   ok
 minute 10:  6,500 distinct stacks   ok
 minute 30:  8,192 distinct stacks   FULL
 minute 31:  every new stack -> insert fails -> sample lost
```

A continuous profiler runs for days. A web server with many request types reaches thousands of
distinct stacks in minutes. After that, every new stack, including the one from the code you
just deployed, is lost. The `map_full` counter told the truth, but the profile was wrong.

The agent side had the same problem in memory: it kept the frames of every stack ever seen in a
hash map (`known`), allocated one by one, never freed.

Making the map bigger only moves the date of the failure. The map has to be emptied.

## 2. Why not just delete the keys?

The obvious fix: read all keys, then delete them. But the kernel program writes the map at the
same time, on every CPU:

```
 CPU 3 (kernel program)              agent
 ───────────────────────              ─────
 p = lookup(key)       ──┐
                         │            read key: count = 41
                         │            delete key
 atomic add 1 to *p    ◄─┘   ← the element is gone, this +1 is lost
```

It is worse than losing one sample. BPF hash maps preallocate their elements and reuse a
deleted one right away. So `p` may point at an element that now belongs to **another** stack,
and the +1 lands on the wrong stack.

So: never delete a key the kernel may still be writing.

## 3. Generations

The config map gets a second field:

```zig
pub const Config = extern struct {
    tgid: u32,        // the process to sample
    generation: u32,  // stamped into every count key
};

pub const CountKey = extern struct {
    stack_hash: u64,
    tgid: u32,
    generation: u32,
};
```

The kernel program reads `generation` when a walk finishes and puts it in the key. The same
stack in two generations is two different keys.

At each report:

```
 report N
 ────────
 1. config.generation = N          from now on, the kernel counts into new keys
 2. read /proc/<pid>/maps,         (useful work, and it gives samples that read
    update unwind tables            the old generation time to finish)
 3. lookup_batch(counts)           1 system call: every key and value
 4. keep the keys whose            in place, in the same buffer
    generation != N
 5. delete_batch(those keys)       1 system call
 6. read the ring buffer           frames for every drained key (section 5)
 7. build the window
```

The old keys no longer change: the kernel only writes keys of the current generation. So
deleting them is safe.

The cost is two system calls per report, whatever the number of stacks. The old snapshot did a
`get_next_key` and a `lookup` per key: two system calls per stack, so 16,000 for a full map.

## 4. The straggler

There is one corner case. A walk on CPU 5 reads `generation = N-1`, and before it inserts its
key, the agent advances to N and drains. What happens to that sample?

```
 CPU 5:  reads generation N-1 ... ... ... insert key{N-1}
 agent:              set N    drain N-1 (done)
```

The key is inserted after the drain, so the drain did not delete it (it only deletes keys it
read). It sits in the map until the next report, which drains every generation that is not
current: `generation != N`, not `generation == N - 1`. So the sample is counted one window
late, but it is counted.

The only way to lose a sample: the straggler's `+1` lands on an existing key in the few
microseconds between the batch read and the batch delete. Step 2 (reading `/proc` and updating
the tables) sits between the advance and the drain to make that window even smaller. I'd rather
write this down than pretend it is zero.

## 5. The frame cache: why two epochs

Counts and frames travel on two different roads:

- the **count** lives in the counts map, and is drained at the report;
- the **frames** go through the ring buffer, once per stack per generation.

Since keys are deleted at every report, a stack that keeps running sends its frames again in
every window (the first sample of each generation misses the map). That is the price of
bounded memory, and it is small: only distinct stacks send frames, not samples.

The kernel sends the record **before** it inserts the key (Ep9). The agent drains the counts
**before** it reads the ring. Together:

```
 kernel:  ring_output(record) ──► insert key
 agent:                              drain keys ──► read ring
```

Any key the agent drained had its record put in the ring before, so reading the ring after the
drain finds it. Every count gets its frames.

But a record can also arrive **one report early**: sent just before report N's drain, with its
key inserted just after. Its frames are read at report N, and its count at report N+1. So the
agent must keep frames for one extra report, and no longer.

That is the frame cache (`cpu/frame_cache.zig`): two epochs, each with a fixed number of slots,
allocated at startup.

```
 report N:   advance: forget epoch B, new records go to B
             drain, read ring -> B
             window N looks in B, then A
 ticks:      read ring -> B
 report N+1: advance: forget epoch A, new records go to A
             drain, read ring -> A
             window N+1 looks in A, then B
```

A record lives through the report it arrived in and the next one. Then its epoch is reused.
Memory is fixed: two epochs of 16,384 stacks and 512k frames each, whatever the run length.

And the window **does not copy frames**. Each stack in the window is a slice pointing into the
cache. That is safe because nothing is forgotten until the next report's `epoch_advance`, and
the report is only valid until then (that is the API's contract). So a report allocates nothing.

## 6. Running at our own pace: the tick

The ring buffer has a fixed size (512 KiB). If the agent read it only at reports, a long report
interval (say 10 s) could let it fill up, and new stacks would be dropped.

So there are two timers in the main loop:

```
 poll on:  report_timer  every interval_ms   -> advance, drain, report
           tick_timer    every 100 ms        -> read the ring into the cache
           pidfd         target exited       -> last report, stop
           cancel        another thread      -> last report, stop
```

The tick does not react to anything. It runs every 100 ms whether the ring is busy or not,
which keeps the cost per second bounded and predictable (the TigerStyle idea of "running at
your own pace"). The sketch: at 99 Hz on 64 CPUs a tick sees at most 634 samples, and only the
new stacks among them take ring space, so the ring cannot fill between two ticks.

For the same reason the kernel program now writes records with `BPF_RB_NO_WAKEUP`: nobody
waits on the ring's file descriptor, so a wakeup per record would only cost the sampled CPU an
interrupt for nothing.

## 7. Every lost sample has a name

Each window now says what it is missing, and why:

```zig
pub const Loss = struct {
    ring_full: u64,         // the ring was full when the stack was new
    counts_full: u64,       // the counts map was full
    frames_missing: u64,    // counted, but the frames never arrived
    records_malformed: u64, // should stay 0: the kernel writes them
    walks_abandoned: u64,   // should stay 0: it would be a bug
};
```

None of these samples are in `Window.samples`. And the accounting from Ep9 still holds,
now across windows that delete their counts:

```
 walks          = repeated + sent + dropped
 sum of windows = walks - dropped - counts_full
```

The root tests check both lines exactly. A real run:

```
walks=1200 kernel=2 sent=107 repeated=1093 dropped=0 counts_full=0
```

1093 + 107 + 0 = 1200. Every walk is accounted for.

## 8. Summary

| Before (Ep9) | Now | Why |
|---|---|---|
| counts only grow | generation per key, drained per report | the map never fills up on long runs |
| snapshot: 2 syscalls per stack | 2 syscalls per report | cheaper as stacks grow |
| frames kept forever in a hash map | two fixed epochs | memory fixed at startup |
| window copies frames | window points into the cache | a report allocates nothing |
| ring read at reports | ring read every 100 ms | long intervals cannot fill it |
| a wakeup per record | no wakeup | no interrupt for nothing |

The next episode is about the bugs this work found: some by reading, and two only by running
the tests as root on a real kernel.
