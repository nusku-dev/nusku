---
date: 2026-11-12
---

# Ep29: Reading DWARF Ourselves

*A function name says where the time went. A source line says what to change. This episode is
the DWARF reader in the server: source files and lines for every frame, and the inlined calls
that a symbol table cannot see at all.*

## Why a symbol table is not enough

Optimized code inlines. In the Zig test app, `std.sort.block` is a few hundred lines of
helpers, and almost all of them are inlined into one function. With symbols alone, the
profile said "20% in `sort.block.block`", and nothing about which of its pieces. The
compiler knows: it writes the inlining into the DWARF debug info, along with a line table that
maps every instruction to a file and line.

So one address can be several frames:

```
address 0x1162de0
  sort.block.mergeInto        block.zig:1002   inlined
  sort.block.block            block.zig:628    ← the function it is compiled into
```

and the profile should show all of them.

1. [Why our own reader](#1-why-our-own-reader)
2. [What it reads](#2-what-it-reads)
3. [The shape in memory](#3-the-shape-in-memory)
4. [Locating an address](#4-locating-an-address)
5. [Frames that expand](#5-frames-that-expand)
6. [Checking it against llvm-symbolizer](#6-checking-it-against-llvm-symbolizer)
7. [Bugs on the way](#7-bugs-on-the-way)
8. [What it shows](#8-what-it-shows)

## 1. Why our own reader

Zig's standard library has a DWARF reader, but it is built to unwind and print one stack
trace of the running program: it loads lazily, keeps what it needs for that, and its API
changes between releases. The server needs something else: load a whole binary's line table
and inline tree **once**, in a compact form, and then answer millions of lookups fast from
many threads. That is a different data structure, so it is our own: about 1 500 lines in four
files, tests included.

| File | Does |
|---|---|
| `dwarf_form.zig` | The byte reader, abbreviation tables, every attribute form |
| `dwarf_line.zig` | Line programs, version 4 and 5, into sorted rows |
| `dwarf.zig` | Units, the function and inline tree, ranges, lookups |
| `dwarf_load.zig` | Finding the sections in an ELF file and decompressing them |

## 2. What it reads

- **DWARF 4 and 5.** GCC and Clang on current distributions write 5; older libraries and
  some toolchains still write 4. Both appear in one process.
- **Sections:** `.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`,
  `.debug_line_str`, `.debug_addr`, `.debug_str_offsets`, `.debug_ranges`, `.debug_rnglists`.
- **Indirect forms** from DWARF 5: `addrx` and `strx` read through the unit's address and
  string-offset bases.
- **Ranges:** a function is `low_pc`/`high_pc` or a list of ranges (`.debug_ranges` in v4,
  `.debug_rnglists` in v5), since an optimized function is often split.
- **Compressed sections** (`SHF_COMPRESSED`), zlib and zstd. Ubuntu's debug files are
  compressed.
- From the tree, only what a profile needs: `subprogram` (functions), `inlined_subroutine`
  (inlined calls, with `call_file` and `call_line`), and `abstract_origin` /
  `specification` to find the name of an inlined function, which lives elsewhere.

Everything else in DWARF (types, variables, locations) is stepped over by its form, never
decoded.

## 3. The shape in memory

`DebugInfo` is five flat arrays:

```
funcs   [Func]   the function tree in pre-order: name, depth, ranges, call file and line,
                 and `end`: the index after its last descendant
ranges  [Range]  low–high pairs, a function's are contiguous
roots   [Root]   top-level functions by start address, for a binary search
rows    [Row]    the line table: address, file, line, sorted by address
files   [[]u8]   file paths, joined with their directory once at load
```

Flat arrays and indexes instead of pointers: they are cheap to free, cheap to measure (the
table counts toward the server's symbol budget, Ep32), and fast to search.

## 4. Locating an address

`locate(address)` gives the frames innermost first:

1. **Find the root**: binary search `roots` for the top-level function containing the address.
2. **Walk down**: among the root's children, the one at depth + 1 whose ranges contain the
   address is the next frame; skip whole subtrees with `end`. That gives the chain, up to 32
   deep.
3. **Lines**: the innermost frame gets the line from the line table. Each outer frame gets the
   `call_file` and `call_line` of the call inlined into it: that is the line in *its* source
   where the call was written.
4. **Name**: the outermost frame keeps the symbol table's name when there is one, since that is
   the name that matches everything else in the profile.

An address outside every function, but inside the line table, still gets its file and line.

## 5. Frames that expand

Before this, a frame was one address and one name. Now naming (`server/naming/resolve.zig`)
can turn one address into several frames, each with `file`, `line` and `inlined`. Merging
stacks compares those too, so two stacks that differ only in which inlined call they were in
stay apart. The lookup cache in naming keeps the whole list per address.

A leaf address is looked up as it is. A return address (every frame above the leaf) is looked
up one byte back, so it lands on the call instruction and gets the call's line, not the line
after it.

## 6. Checking it against llvm-symbolizer

A DWARF reader that is almost right is worse than none: a wrong line sends you to the wrong
code. So it was checked against `llvm-symbolizer --inlining`, frame by frame, on 3 000 addresses
from each of:

- the Zig test app (DWARF 5, heavy inlining),
- this machine's **libc** (DWARF 5, zlib-compressed, from its debug file),
- the Go test app (DWARF 4),
- `nusku-app` itself (DWARF 5, LLVM).

All four match exactly: functions, files, lines, and the inline chain. The differences on the
way were bugs in the comparison script (duplicate addresses, names with spaces), and then
bugs in the reader, below.

## 7. Bugs on the way

- **A crash in the abbreviation table.** Abbreviations were returned as pointers into a hash
  map, and reading the next one could grow the map and move them. It crashed only on big
  binaries. Abbreviations are now copied out.
- **zlib and zstd need their window.** Both decompressors in Zig's standard library take a
  window buffer; without a big enough one, large sections failed. They get the full window now.
- **Paths joined twice.** In DWARF 5, directory 0 is the compilation directory itself, and the
  file table already counts from it. Joining it again gave `/src/proj/src/proj/main.c`.
- **Sizes and offsets.** A `u24` size read as an `int`, and an offset kept as `u32` where
  64-bit DWARF needs `u64`. Small things, found by libc.

## 8. What it shows

In the app, the function details panel lists a function's **hottest lines**, and functions
that ran mostly inlined carry an **inlined** badge; in the flame graph, inlined frames are
frames like any other, so the 20% in `sort.block.block` now opens into `mergeInto`,
`mergeExternal` and `swap`. In the CLI (Ep31), the top functions show their hottest line and
the call tree marks inlined frames:

```
  19.8%     sort.block.block__anon_3491  self 1.3%
  11.4%     ├─ sort.block.mergeInto__anon_3556 inlined  self 9.7%
```

A binary without DWARF still gets names from its symbols; it just has no lines. The profile
says so (Ep30).
