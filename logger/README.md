# shared

What more than one part of nusku needs, kept in one place so that no part has to import
another for it. The agent and the server never import each other; both import the
`protocol` types from here. Every module imports them from `shared` directly, never through
another module.

Nothing in here does a job of its own. These are types, and the small readers every part
needs.

## Public API

Everything is in `root.zig`.

| | |
|---|---|
| `protocol` | what crosses between the agent and the server, see below |
| `File` | a file read with plain system calls: `open`, `read`, `read_at`, `size_bytes`, `stat`, `deinit`. No allocation and no `std.Io`, so a signal handler or a thread of the agent can use it. Errors are the few that matter (`NotFound`, `PermissionDenied`, `ProcessNotFound`, …) |
| `directory.Directory` | a directory's entries: `open`, `next`, `deinit` |
| `elf` | reading ELF files from their bytes: `find` a section, `bytes_of` it (decompressing a compressed one with `decompress`), the executable `segments_executable`, the `segment_mapped` at a mapping's offset, and the `load_bias` |
| `dwarf_form` | reading DWARF's encodings: `Reader` (`uleb`, `sleb`, `string`, `offset`, …), abbreviations, attributes. The agent reads Go's runtime layout with it, and the server source lines and inlined calls |

### protocol

| | |
|---|---|
| `Message` | one report of a run, one window of time: when, how long, the samples (and samples lost), the `stacks` as raw addresses with their counts, the executable `regions` the addresses fall in, and the kernel's identity |
| `RunEvent` | what an agent's `Run` yields: a `report` (a `Message`), a binary on its way (`binary_offer`, `_begin`, `_chunk`, `_end`, `_abort`), or `stopped` |
| `Answer` | the server's reply to an event: `none`, `wanted`, `unwanted`, `later`, `resend` |
| `binary` | a binary sent for its symbols: the `Offer` (path, build ID), the `Header` (section sizes), its `Chunk`s, and the `Section`s it may hold |
| `kernel` | how kernel frames are named: the kernel's id from its build ID and `_text` address |
| `probe` | a function probe's `Info`, `Totals` and `Report`, with a 64-bucket histogram of call times |
| `ProcessInfo`, `ProcessFrame`, `Machine` | one look at every process and at the machine's CPU |
| `Metric`, `RunStop`, `WatchStop` | what a run can measure, and why a run or a watch ended |

Every event points into the sender's memory, valid until its next event. A receiver copies
what it keeps (`Message.clone`).

## Tests

`zig build test` from the repository's root.
