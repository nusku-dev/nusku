
# testing

How we know the profiles are right. Unit tests prove each piece does what its code says; this
folder proves the whole tool tells the truth about real programs.

Each app here burns CPU in a known pattern: so much time in this function, so much in that
one, through these call paths. `make check` profiles each of them with `nusku-cli` and checks
the report against the numbers the app was written to produce.

## Use

Needs root (it runs `sudo`), a C compiler, `go` and `zig`.

```sh
cd testing
make check                 # build nusku-cli and the apps, profile each, check each
make DURATION=10 check     # longer runs, tighter numbers
make profile-go            # profile one app and show the report (also -c, -zig, -threads)
make clean
```

```
== c app
  pass  complete stacks                   98.8%  (expected >95%)
all checks passed
== go app
  pass  complete stacks                  100.0%  (expected >95%)
  pass  stopped at the Go system stack     0.0%  (expected <5%)
all checks passed
```

## The apps

| App | What it proves |
|---|---|
| `apps/c` | self time against total time; recursion; a call through libc (`qsort` calling back into the app), so the walk must unwind through libc with its `.eh_frame` |
| `apps/threads` | four threads: busy, half busy, in the kernel reading `/dev/zero`, and asleep. The sampling rate must add up to 2.5 cores, a sleeping thread must never show, and the kernel frames must have names |
| `apps/zig` | the same pattern as the C app, in Zig, with sorting through `std.mem.sort`, and a clock read in the vDSO with no system calls |
| `apps/go` | the same pattern in Go: unwinding with Go's `pclntab`, through the runtime (`sort.Slice`) and back, and through Go's switch to its system stack |
| `check-exit` | a launched program that exits before `--duration`: profiling stops and says so |

## expect.txt

Each app's `expect.txt` has one check per line. `check.sh` reads it against the folded stacks
`nusku-cli prof --folded` wrote.

```
samples   >250               a sanity floor
complete  >95                at least 95% of the samples have their whole stack
self  hot_leaf 50            hot_leaf is the running function in 50% of the samples, ±5 points
total run      >95           run is on the stack in at least 95% of the samples
rate  99                     samples per second: 99 ±5% (one busy thread)
path  run;hot;hot_leaf 50    this call path in 50% of the samples
kernel 40                    a kernel frame in 40% of the samples
kernel_named >95             of those, the share whose kernel frames have names
go_switch <5                 at most 5% stop where Go switches to its system stack
```
