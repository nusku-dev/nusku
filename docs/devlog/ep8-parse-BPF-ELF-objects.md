---
date: 2026-10-11
---

# How Nusku Reads BPF ELF Objects

today we will implement a lightweight ELF parser for Nusku.

When Zig compiles our eBPF program, it produces an ELF object file (`oncpu.bpf.o`). This file contains more than machine instructions: it also contains sections, symbols, map definitions, and relocation information.

Our userspace loader needs to read this information to understand the object and prepare it for loading into the Linux kernel.

Instead of depending on a complete ELF library, Nusku implements the specific functionality it needs.

## 2. The big picture

```text
oncpu.ebpf.zig
      |
      v
Zig compiles the BPF program
      |
      v
  oncpu.bpf.o
      |
      v
  ELF.init()
      |
      v
Validate ELF header and section table
      |
      v
Find sections, symbols and relocations
      |
      v
Read map definitions and prepare BPF programs
      |
      v
Userspace loader loads the program
```

## 3. What is ELF?

ELF stands for *Executable and Linkable Format*. It is a binary format used by Linux for executables, shared libraries, and object files.

Our BPF object uses ELF to organize the information needed by the loader.

Important parts:

- **ELF header:** describes the file's format and where its metadata is located.
- **Section header table:** describes the sections contained in the file.
- **Sections:** hold program instructions, map definitions, symbols, strings, and other data.
- **Symbol table:** identifies named functions and variables.
- **Relocations:** describe places in the program that need to be patched with the correct addresses or references.

For our parser, three important sections are:

| Section | Purpose |
|---|---|
| `perf_event` | Contains our on-CPU BPF program. |
| `.maps` | Contains map definitions such as `stacks`, `counts`, and `target_pid`. |
| `license` | Contains the BPF program's license information. |

## 4. The `ELF` structure

```zig
pub const ELF = struct {
    bytes: []const u8,
    shoff: usize,
    shentsize: usize,
    shnum: usize,
    shstrndx: usize,
};
```

These fields describe the original ELF file and its section metadata.

- `bytes`: the complete ELF file in memory.
- `shoff`: the byte offset where the section header table begins.
- `shentsize`: the size of each section header.
- `shnum`: the number of section headers.
- `shstrndx`: the index of the section containing section names.

**Why store offsets instead of copying everything?**

The parser can access information directly from the original byte slice. It doesn't need to allocate separate memory for every section.

The `ELF` structure borrows the bytes, so they must remain valid while the parser uses them.

## 5. Understanding `ELF.init()`

`init()` validates the ELF file before allowing other methods to inspect it.

It checks the following:

1. **Minimum size:** the file must be large enough to contain the ELF64 header.
2. **Magic bytes:** the first four bytes must be `0x7f`, `E`, `L`, `F`.
3. **File format:** the file must use ELF64 and little-endian byte order.
4. **Architecture:** the machine type must be `EM_BPF`, whose numeric value is `247`.
5. **Section metadata:** the section header entries must be large enough, and the section-name table index must be valid.
6. **Bounds:** the complete section header table must fit inside the file.

For example:

```zig
if (bytes.len < 64) return error.Truncated;
if (!std.mem.eql(u8, bytes[0..4], "\x7fELF")) {
    return error.NotElf;
}
if (bytes[4] != 2 or bytes[5] != 1) {
    return error.Unsupported;
}
```

These checks prevent the parser from blindly interpreting arbitrary bytes as a valid BPF ELF file.

The parser also uses checked arithmetic when calculating the section table's size and end offset. This helps prevent integer overflow and out-of-bounds access.

## 6. Understanding sections

A section is a named region of data inside the ELF file.

Our internal `Section` structure stores the metadata we need:

```zig
const Section = struct {
    index: usize,
    name: u32,
    kind: u32,
    offset: usize,
    size: usize,
    link: u32,
    info: u32,
};
```

- `index`: the section's index in the section header table.
- `name`: an offset into the section-name string table.
- `kind`: identifies the section type.
- `offset`: where its data begins in the ELF file.
- `size`: how many bytes it contains.
- `link`: references another section, depending on the section type.
- `info`: contains additional metadata, such as the target section for relocations.

Notice that `name` is an offset, not the actual section name. ELF stores section names in a string table, and the parser resolves those names when needed.

### `sectionAt()`

```zig
fn sectionAt(self: ELF, index: usize) Error!Section
```

Reads the metadata for a section at a given index.

It reads specific fields from the section header using their defined byte offsets.

For example:

```zig
.kind = try readInt(u32, self.bytes, h + 4),
.offset = @intCast(try readInt(u64, self.bytes, h + 24)),
.size = @intCast(try readInt(u64, self.bytes, h + 32)),
```

ELF64 section headers have a defined binary layout. The parser uses these offsets to interpret the raw bytes correctly.

`sectionAt()` is private because it is an implementation detail used by the public ELF operations.

### `findSection()`

```zig
pub fn findSection(self: ELF, name: []const u8) Error!Section
```

Searches for a section by name.

For example:

```zig
const maps = try elf.findSection(".maps");
```

Internally, it reads the section-name string table, walks through the section headers, resolves each name, and compares it with the requested name.

It returns `error.SectionNotFound` if no matching section exists.

### `readSectionData()`

```zig
pub fn readSectionData(self: ELF, section: Section) Error![]const u8
```

Returns the raw bytes belonging to a section.

```zig
const section = try elf.findSection("perf_event");
const instructions = try elf.readSectionData(section);
```

The function calculates the end offset, checks that it stays within the file, and returns a slice of the original bytes.

It doesn't copy the section into a new allocation.

## 7. Understanding symbols

A symbol gives a name to something in the ELF file, such as a function or a variable.

Our BPF object has symbols such as:

- `onCpusample`: the BPF program.
- `stacks`: the stack-trace map definition.
- `counts`: the sample-count map definition.
- `target_pid`: the target process map definition.
- `LICENSE`: the license data.

### `findSymbol()`

```zig
pub fn findSymbol(self: ELF, name: []const u8) Error!Symbol
```

Searches the symbol table for a matching global symbol.

Each ELF64 symbol-table entry is 24 bytes. The parser reads the symbol's name offset, binding information, section index, value, and size.

It ignores non-global symbols:

```zig
if (symbols[off + 4] >> 4 != STB_GLOBAL) continue;
```

The upper four bits of the `st_info` byte identify the symbol's binding. `STB_GLOBAL` means the symbol is globally visible.

This matters because Zig can emit local symbols with qualified names alongside global symbols. Matching only global symbols helps avoid selecting the wrong entry.

For example:

```zig
const sym = try elf.findSymbol("stacks");
```

The returned `Symbol` tells us which section contains the symbol, its value, and its size.

**Important:** a symbol's `value` is not universally a file offset. For symbols in sections, it commonly represents a section-relative offset in relocatable ELF objects. The loader must interpret it in the context of the symbol's section and ELF format.

## 8. How Nusku reads map definitions

Our BPF source declares maps in the `.maps` section:

```zig
export var stacks: MapDef linksection(".maps") = .{
    .map_type = BPF.MAP.TYPE.STACK_TRACE,
    .key_size = 4,
    .value_size = MAX_STACK_DEPTH * 8,
    .max_entries = MAX_ENTRIES,
};
```

The loader needs these values to create the corresponding kernel BPF maps.

Our ELF parser provides the operations needed to locate and inspect them:

```zig
const maps = try elf.findSection(".maps");
const bytes = try elf.readSectionData(maps);
const sym = try elf.findSymbol("stacks");
```

The loader can use the symbol's location to find the map definition's bytes within `.maps`, then decode the four `u32` fields.

For our current definitions, each map occupies 16 bytes:

| Field | Size |
|---|---:|
| `map_type` | 4 bytes |
| `key_size` | 4 bytes |
| `value_size` | 4 bytes |
| `max_entries` | 4 bytes |
| **Total** | **16 bytes** |

The ELF parser does not itself create the kernel maps. It provides the metadata that the loader needs to create them.

## 9. Understanding relocations

A relocation describes a location in a program that needs to be adjusted when the loader resolves a reference.

For example, BPF instructions may reference a map whose actual kernel file descriptor or reference is not known when the object is compiled.

The ELF object records relocation information so that the loader can identify and patch these references.

### `relocationsFor()`

```zig
pub fn relocationsFor(
    self: ELF,
    program: Section,
) Error!RelocIterator
```

This function searches for a relocation section that targets the supplied program section.

It checks:

```zig
if (rel.kind != SHT_REL or rel.info != program.index) continue;
```

- `SHT_REL` identifies a relocation section without an explicit addend field in each relocation entry.
- `rel.info` identifies the section being modified.
- `rel.link` identifies the section containing the symbols used by the relocations.

When it finds a match, the parser returns the relocation entries and associated symbol-table bytes through a `RelocIterator`.

If no matching relocation section exists, it returns an empty iterator.

The parser finds and exposes relocation data; the relocation logic is responsible for interpreting and applying it.

## 10. Error handling

The parser uses a custom `Error` type imported from `utils.zig`.

Errors include:

- `Truncated`: required bytes are missing or an offset extends beyond the file.
- `NotElf`: the file does not have the ELF magic bytes.
- `Unsupported`: the file format or architecture is not supported.
- `SectionNotFound`: the requested section cannot be found.
- `SymbolNotFound`: the requested global symbol cannot be found.

Using explicit errors lets the loader reject malformed or unsupported objects instead of silently reading invalid data.

## 11. Summary

The responsibilities of `elf.zig` are:

- Validate that the input is a supported ELF64 BPF object.
- Read section headers and locate named sections.
- Return raw section data safely.
- Find global symbols and their locations.
- Locate relocation entries for a program section.
- Provide the metadata required by the userspace BPF loader.

**The key idea:** `elf.zig` understands the structure of the compiled BPF object. It doesn't execute the program or create kernel maps by itself; it gives the loader the information needed to do those jobs.
