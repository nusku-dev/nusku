# src: nusku-cli

The command-line program. It is a thin front end: the commands come from the
[`cli`](../cli/README.md) framework, every profile comes from the [`client`](../client/README.md),
and what is left here is reading flags and drawing results on a terminal.

## Commands

| | |
|---|---|
| `nusku-cli prof` | profile a running process (`--pid`) or launch one (`--exec`): the top functions live while it runs, then the top functions, the call tree and what the profile could not see. `--save` keeps it as a saved run, `--repeat N` runs it N times as one series, `--folded` writes stacks for flame graph tools |
| `nusku-cli ps` | every process of the machine with its CPU and memory, the busiest first, redrawn every second |
| `nusku-cli watch` | a session that keeps profiling in the background: `prof`, `launch`, `watch <id>` to look at one live, `stop`, `quit` |
| `nusku-cli probe` | count and time every call of one function in a running process |

`nusku-cli <command> --help` has the whole story of each. All of them take `--log-level`
(or `NUSKU_LOG_LEVEL`) and `--log-format` (`text`, `logfmt`, `json`). Logs go to stderr, so
results can be piped.

The binary is static (musl): it runs on any x86_64 Linux without installing anything. The one
thing it cannot do is load `libdebuginfod`, so it does not download debug symbols; the app and
web builds do.
