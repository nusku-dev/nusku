---
date: 2026-10-31
---

# Ep13: Unwinding Through the vDSO

Ep12 ended with a lesson from a failing test: a program that reads the clock in a hot path
loses the callers of those samples. This episode fixes that, and on the way finds out that our
own test programs never ran the code we were trying to fix.

The short version:

> The vDSO has no file on disk, but every process on a kernel maps the same one. So the agent
> copies its own, once, and builds its unwind table like for any other library.

## 1. What the vDSO is

Some system calls are asked so often, and do so little, that entering the kernel costs more
than the work. Reading the clock is the classic one: a web server may read it several times per
request.

So the kernel maps a small shared library into every process: the **vDSO** (virtual dynamic
shared object). It holds `clock_gettime`, `gettimeofday`, `time` and `getcpu`, and it reads the
clock straight from memory the kernel keeps up to date, without a system call.

In `/proc/<pid>/maps` it looks like this:

```
7ffe4a500000-7ffe4a502000 r-xp 00000000 00:00 0                          [vdso]
```

Executable, 8 KiB, and no file: inode 0, and a name in brackets instead of a path.

## 2. Why its samples lost their callers

To unwind a frame, the kernel program needs the rows of the function it is in (Ep9). The rows
come from the `.eh_frame` section of the file the code was loaded from. The vDSO has no file,
so `unwind/tables.zig` gave it no table:

```zig
// [vdso] and anonymous code (JIT) have no file to read.
if (region.path[0] != '/') return .{ .unavailable = .unreadable };
```

Without a table the walk falls back to frame pointers. But the vDSO is built with `-O2` and
does not keep them. So from a sample inside `clock_gettime`, the walk either stopped at once or,
worse, followed a `rbp` that belonged to the caller and silently skipped a frame.

## 3. Where to get the vDSO's unwind information

The vDSO is a real ELF shared library: the kernel builds it at compile time and maps the whole
image. Dumping it from a process's memory and reading it:

```
$ readelf -S -l -n vdso.so
  Number of section headers:         16
  [ 9] .eh_frame_hdr     PROGBITS   0000000000000554
  [10] .eh_frame         PROGBITS   00000000000005b0
  [11] .text             PROGBITS   00000000000006f0
  LOAD           0x0000000000000000 0x0000000000000000 ...
    Build ID: 49ad9c464702a756ecc773106cb004c481333bda
$ readelf --debug-dump=frames vdso.so | grep -c FDE
10
```

Section headers, an `.eh_frame` with 10 FDEs (one per function), a build ID, one executable
segment at offset 0. Everything `unwind/` already knows how to read.

There were two ways to get these bytes:

| | read the target's vDSO | copy the agent's own |
|---|---|---|
| how | `/proc/<pid>/mem` at the [vdso] address | a pointer to our own mapping |
| rights | ptrace access to the target (`CAP_SYS_PTRACE`) | none |
| cost | once per target | once per run |
| same image? | yes, by definition | yes, for every 64-bit process on this kernel |

Every 64-bit process on one kernel maps the same image: it is part of the kernel. So the agent
copies its own, and needs no extra right. That matters, because the agent is meant to run with
`CAP_BPF` and `CAP_PERFMON`, not as full root.

## 4. Reading our own memory, carefully

`target/vdso.zig` does it once at startup. Reading raw memory through a pointer is the one
place where a mistake is a crash instead of an error, so it checks twice before it reads:

```zig
const header_address = getauxval(auxv_sysinfo_ehdr);
if (header_address == 0) return null; // The kernel maps no vDSO (vdso=0).

const mappings = try process_maps.read(arena.allocator(), process.current_pid());
const mapping = for (mappings) |mapping| {
    if (std.mem.eql(u8, mapping.path, path)) break mapping;
} else return null;

// Two sources must agree before memory is read: the kernel's auxiliary vector and our maps.
if (mapping.start != header_address) return null;
```

The **auxiliary vector** is a small table the kernel hands every process at start;
`AT_SYSINFO_EHDR` is where it mapped the vDSO's ELF header. Our maps say where the `[vdso]`
mapping starts and ends. Only when both agree does the agent copy exactly that mapping, and
then it checks the ELF magic. From there the bytes are treated like any untrusted file.

## 5. A target whose vDSO is not ours

"Every process maps the same image" has one exception: a 32-bit process maps the 32-bit vDSO,
a different library. Using our 64-bit table for it would produce wrong stacks, which is worse
than short ones.

The two images have different sizes, so the size of the target's `[vdso]` mapping tells them
apart:

```zig
if (!image.matches(region.end - region.start)) return .{ .unavailable = .vdso_unknown };
```

`vdso_unknown` is a new reason in the report's unwind coverage. The rule of the agent stays the
same: a wrong stack is never shown as a right one; it is cut, and the cut has a name.

## 6. The test that never ran the vDSO

The end-to-end test forks a child whose loop only reads the clock, profiles it for real, and
checks that stacks inside the vDSO climb out of it. The first run:

```
vdso e2e: 49 samples, 0 in the vDSO, 0 of those complete
```

Zero. Not "the unwinding is broken": not a single sample was inside the vDSO at all.

The machine's clock source was `tsc`, which the vDSO reads without the kernel. So the vDSO
should have been used. A small program settled it:

```
$ strace -c -e trace=clock_gettime ./clk     # 1000 calls of std.os.linux.clock_gettime
100.00    0.004318     4     1000    clock_gettime
```

1000 calls, 1000 system calls. In a **static musl build**, Zig's standard library does not find
the vDSO, and makes a real system call for every clock read. Our test child never ran vDSO code.
It also explains Ep12's mystery: the old burn loop had 725 of 1200 samples in kernel mode.

So the test child now calls the vDSO directly. It finds `__vdso_clock_gettime` in the vDSO's own
symbol table (`.dynsym` and `.dynstr`), and calls it through a function pointer. A forked child
maps the vDSO at the same address, so the pointer is valid in the child too. A small non-root
test checks that the function found tells the same time as the system call.

The second run:

```
vdso: 2150 of 2221 bytes of .text have a row
vdso e2e: 49 samples, 43 in the vDSO, 43 of those complete
All 92 tests passed.
```

43 of 49 samples inside the vDSO, and every one of them walked out of it, through the child's
own code, to the outermost frame. The 71 bytes of `.text` without a row are the padding between
functions.

(And a side note for later: any static musl Zig program pays a system call for every clock
read, our own tools included.)

## 7. Test code out of production

This step needed new test code: a child process that calls the vDSO, and an end-to-end test.
Test code should not live next to the code that runs on a production machine. So it has its own
folder now:

```
agent/
  testing/
    process.zig            child processes for tests: burners, sleepers, the clock reader
    e2e/
      vdso_unwind.zig      the end-to-end test of this episode
```

The rule: production code never imports anything under `testing/`. Only `test` blocks and the
test sections at the bottom of files do. Zig only compiles what is referenced, so the production
binary contains none of it, and that is checked:

```
$ nm zig-out/bin/nusku | grep -c -E "clock_read_loop|vdso_clock_gettime"
0
```

To build without the tests at all, delete the folder: only the test build notices.

## 8. Summary

- The vDSO is a real ELF library without a file. Its samples lost their callers.
- The agent copies its own vDSO once (no extra rights needed), after two sources agree on its
  address, and builds its table like any other binary's. 97% of its code has rows.
- A target with another vDSO (32-bit) is recognized by size, and gets `vdso_unknown`, not a
  wrong table.
- Static musl Zig programs never use the vDSO: the test calls it directly.
- Test-only code lives in `agent/testing/`, out of the production binary.
