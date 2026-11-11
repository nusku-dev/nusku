---
date: 2026-11-12
---

# Ep28: Names You Can Trust

*The first profile in the app showed `0x12e892c`, `Unnamed`, `Unnamed`. This episode is
everything between an address and a name a person recognizes: which file the address belongs
to, which of several names at that address to show, and where to find names a binary does
not carry.*

A sample is a list of addresses. To name one, Nusku needs three things: the **file** the
address is in, the **identity** of that file (so the server can keep its table and share it
between processes), and a **symbol table** for it. Each one failed somewhere.

1. [Every file needs an identity](#1-every-file-needs-an-identity)
2. [Zig binaries had none](#2-zig-binaries-had-none)
3. [Which name at an address](#3-which-name-at-an-address)
4. [Names a binary does not carry](#4-names-a-binary-does-not-carry)
5. [debuginfod](#5-debuginfod)
6. [Names that are right but strange](#6-names-that-are-right-but-strange)
7. [What is left](#7-what-is-left)

## 1. Every file needs an identity

The server keys symbol tables by **build ID**: the agent offers a binary by its ID, the
server says whether it already has it, and the naming step looks tables up by it. A file with
no build ID was never offered, so its frames stayed addresses for good.

Most distribution binaries have a GNU build ID note. Many others do not: Go binaries carry
their own note instead, some toolchains write none, and a binary built in a hurry may have
neither. `agent/target/build_id.zig` now finds an identity for every ELF file, in order:

| Source | ID |
|---|---|
| GNU build ID note (`NT_GNU_BUILD_ID`) | the note, as it is |
| Go build ID note | SHA-256 of `"nusku go"` + the note, cut to 20 bytes |
| Neither | SHA-256 of `"nusku file"` + device, inode, size and modification time, cut to 20 bytes |

The kind goes into the hash first, so a Go ID can never equal a file ID by accident.
The file one is weaker, since it names *this copy* of the file rather than its contents, but a
rebuild changes its inode or time, so the server never names a new build with an old table.
That is the property that matters: an identity that is never wrong, even if it is sometimes
not shared.

## 2. Zig binaries had none

The app itself, `nusku-app`, showed no names. Zig's self-hosted backend in Debug writes no build
ID, and it ignores `--build-id`. Both builds now ask for LLVM and LLD, which do:

```zig
exe.build_id = .fast;
exe.use_llvm = true;
exe.use_lld = true;
```

The file-identity fallback above would also have named it; the GNU note is better because it
is the same for two copies of the same build.

## 3. Which name at an address

A symbol table often has several names at one address: `__libc_start_main` and
`__libc_start_main_alias_2`, a function and its versioned alias `memcpy@GLIBC_2.14`. The
first one in the table won, which is how the UI ended up showing `_alias_2`.

`symbol_table.zig` now ranks them the way a person would pick:

1. **Global** over weak over local: the exported name is the one in the documentation.
2. Then the **shortest**: aliases are usually longer.
3. And the `@version` suffix is dropped: `memcpy@GLIBC_2.14` is shown as `memcpy`.

## 4. Names a binary does not carry

Distributions strip their binaries. What is left is `.dynsym`, the exported functions only, so
every internal function in libc reads as the nearest export, or as nothing. The full table
lives in a separate **debug file**, found by build ID.

When the binary that arrives is stripped, the server's builder looks for its debug file
(`server/symbols/debug_files.zig`):

1. **Locally**: `/usr/lib/debug/.build-id/ab/cdef….debug`, which is where `-dbgsym` and
   `-dbg` packages put them.
2. **Over the network**, through debuginfod (next section), when `DEBUGINFOD_URLS` is set.

From the debug file it takes the full `.symtab` and, when it is there, the DWARF sections for
source lines (Ep29). A section marked compressed (`SHF_COMPRESSED`, zlib or zstd) is
decompressed first. The agent marks which sections it sent compressed, so the server does
the same for sections it received from a live binary.

## 5. debuginfod

debuginfod is a protocol for fetching debug files by build ID over HTTP. Ubuntu, Fedora,
Debian and Arch run public servers; on this machine `DEBUGINFOD_URLS` points at Ubuntu's.

The first try used Zig's standard HTTP client. It failed on the server's TLS certificate chain
(`CertificateIssuerMismatch`), and fixing a TLS stack is not this project's job. The server now
**loads `libdebuginfod` at runtime** with `dlopen`, the same library `gdb` and `perf` use:

- It is optional. Without the library, the server logs once and works without the network.
- It fetches the **whole debug file** first, for its DWARF. If that is not there, or too big,
  it fetches only the `.symtab` and `.strtab` **sections**, which is enough for names. For
  WebKit that is 33 MB instead of a multi-gigabyte debug file.
- A progress callback aborts any fetch that takes more than **15 s**, so one slow download
  cannot hold up every other binary behind it.
- The client is not thread safe, so only the builder thread uses it.
- Downloads land in the user's debuginfod cache and are reused by every tool on the machine.

The CLI is a static musl binary and cannot `dlopen`, so it uses local debug files only. The app
uses both.

Sending a build ID to a public server tells that server which binaries you run. It is the
same trade every debuginfod client makes, and turning it off is unsetting one variable.

## 6. Names that are right but strange

Once names worked, the profile of an idle app was full of `finish_task_switch.isra.0`. That
is a correct name: it is the kernel function a thread is in when it has just been switched
back in, and `.isra.0` is GCC's suffix for a copy it specialized. An idle GUI app spends its
samples waking up and going back to sleep, so the kernel dominates. The fix here was not code
but colors: kernel frames are their own family (purple) in the flame graph, so they read as
"the kernel" at a glance.

## 7. What is left

- **Deleted binaries have no identity.** A process whose binary was replaced on disk (every
  rebuild during development) maps a file marked `(deleted)`, and the agent skips it,
  because the file at that path is no longer the code that runs. Reading it through
  `/proc/<pid>/map_files/` would still work.
- **JIT code** (JavaScript, Java, .NET) has no file at all. That needs perf maps, and is for
  later.
