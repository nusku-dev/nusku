# server

The server keeps what the agents report and turns it into profiles people can read. It holds
the last windows of each target, builds a symbol table for every binary the agents send, and
names each address in a stack: function, source file and line, inlined calls included. It also
runs the jobs (a profile, the processes watch, a function probe), each on a thread of its own.

For now the server and its agents live in one process: the [`client`](../client/README.md)
starts both, and `Controller` runs each agent on a thread and feeds the server directly.
Nothing goes over a network yet. The agent and server meet only through the types in
`shared/protocol`, so a transport can go between them later without changing either.

## Public API

Everything is in `root.zig`.

**`Controller`: run jobs.** This is what the client uses.

```zig
const server_lib = @import("server");

var server: server_lib.Server = undefined;
try server.init(gpa, .{});                 // starts the symbols builder thread: keep `server` in place
defer server.deinit();

var controller: server_lib.Controller = undefined;
try controller.init(gpa, &server, .{});
defer controller.deinit();

const started = try controller.start(.{ .profile = .{ .pid = pid, .interval_ms = 1000 } });
// ... later, any number of times while it runs:
var arena = std.heap.ArenaAllocator.init(gpa);
const profile = try server.profile(arena.allocator(), .{ .target = started.target.? }, .all_built);
// ...
const done = try controller.stop(started.job);    // or controller.wait(job) for a duration
```

| | |
|---|---|
| `Controller.start(spec)` | starts a job and returns `Started`: its `job`, plus its `pid` and `target` (a profile) or `probe` (a probe) |
| `Spec` | `.profile` (a pid, or a program for the agent to launch; metrics, interval, duration), `.processes` (interval, duration), `.probe` (pid, function, module, interval, duration) |
| `stop(job)` / `wait(job)` | end it now, or wait for it to end; either returns why it ended (`Done`) |
| `running(job)`, `interrupt()` | is it still going; stop every job (safe from a signal handler) |

The controller lives as long as its process, so it reaps the programs its agents launched,
kept running or not, as they end: whenever it starts a job or is asked about one.

**`Server`: ask what was kept.**

| | |
|---|---|
| `profile(arena, query, names)` | a target's windows named and merged into a `Profile`: stacks of `Frame`s (function, file, line, module, inlined) with their sample counts. The `Query` picks a time range; `stacks = false` gives only the counts, cheap enough for every second. `names = .all_built` waits for the binaries still being built |
| `processes(arena)` | the latest frame of the processes watch |
| `probe(arena, id)` | what a function probe has reported so far, one point per interval |
| `feed(pid)`, `probe_feed()`, `watch_take(event)` | how an agent's events come in. `Feed.take(event)` returns the `Answer` to give the agent back (want the binary, not needed, later, resend). The `Controller` does this for you |

A `Profile` is allocated in the arena you pass, and stays valid until you free it.


## Tests

```sh
zig build test                    # from the repository's root
sudo zig build test -Dapp=false   # with the end-to-end ones: a real program profiled and named
```

`testing/` has a CPU burner to profile and a hand-made symbol table for the naming tests.
