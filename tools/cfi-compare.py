#!/usr/bin/env python3
"""Compares the unwind rows that unwind-dump computes with what readelf says, for one binary.

Run from the repository root, after zig build.   Usage: cfi-compare.py FILE
"""
import collections
import re
import subprocess
import sys

REGS = ["rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "ra"]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout


def parse_dump(text):
    """A list of [begin, end, rows, error]. A row is (loc, cfa, {register: rule})."""
    fdes = []
    for line in text.splitlines():
        if line.startswith("FDE "):
            begin, end = line.split()[1].split("..")
            fdes.append([int(begin, 16), int(end, 16), [], None])
        elif line.startswith("ROW "):
            parts = line.split()
            fdes[-1][2].append((int(parts[1], 16), parts[2], dict(zip(REGS, parts[3:3 + len(REGS)]))))
        elif line.startswith("ERROR "):
            fdes[-1][3] = line.split()[1]
    return fdes


def tidy(line):
    # readelf writes a register held in another register as "r5 (rdi)": two words for one
    # cell. Keep only the name, written the way we write it, and call the return address "ra".
    line = re.sub(r"\br\d+ \((\w+)\)", r"\1", line)
    return re.sub(r"\brip\b", "ra", line)


def parse_readelf(text):
    fdes = []
    cies = {}  # offset -> its starting row
    header = None  # readelf writes the column names again only when they change
    state = None  # "cie", "fde", or None between tables
    cie_offset = None
    for line in text.splitlines():
        m = re.match(r"([0-9a-f]+)\s+[0-9a-f]+\s+[0-9a-f]+\s+CIE\b", line)
        if m:
            state = "cie"
            cie_offset = int(m.group(1), 16)
            continue
        m = re.search(r"\sFDE cie=([0-9a-f]+) pc=([0-9a-f]+)\.\.([0-9a-f]+)", line)
        if m:
            fdes.append([int(m.group(2), 16), int(m.group(3), 16), [], None, int(m.group(1), 16)])
            state = "fde"
            continue
        parts = tidy(line).split()
        if not parts:
            state = None  # a blank line ends a table
            continue
        if parts[0] == "LOC":
            header = parts[1:]
        elif state and header and re.fullmatch(r"[0-9a-f]{8,16}", parts[0]):
            cells = dict(zip(header, parts[1:]))
            cfa = cells.pop("CFA", "?")
            regs = {r: "-" for r in REGS}
            regs.update(cells)
            row = (int(parts[0], 16), cfa, regs)
            if state == "cie":
                cies[cie_offset] = row
            else:
                fdes[-1][2].append(row)

    # readelf prints no rows for a function whose only row is the CIE's starting row.
    for f in fdes:
        if not f[2] and f[4] in cies:
            _, cfa, regs = cies[f[4]]
            f[2].append((f[0], cfa, dict(regs)))
    return fdes

def norm(cell):
    # readelf writes "u" for every register that no instruction mentions, and also for one
    # that is explicitly undefined. We write "-" for the first kind and "u" only for the
    # second, so they are compared as the same.
    return "u" if cell in ("-", "n/a", None) else cell


def diff_rows(ours, theirs):
    """None if the rows agree, else (kind, text)."""
    if len(ours) != len(theirs):
        return ("row count", f"{len(ours)} rows, readelf has {len(theirs)}")
    for x, y in zip(ours, theirs):
        if x[0] != y[0]:
            return ("row address", f"a row at {x[0]:x}, readelf has one at {y[0]:x}")
        if x[1] != y[1]:
            return ("CFA", f"at {x[0]:x}: CFA {x[1]}, readelf says {y[1]}")
        for r in REGS:
            if norm(x[2].get(r)) != norm(y[2].get(r)):
                return (f"register {r}", f"at {x[0]:x}: {r} {x[2].get(r)}, readelf says {y[2].get(r)}")
    return None


def main():
    path = sys.argv[1]
    ours = parse_dump(run(["./zig-out/bin/unwind-dump", path]))
    theirs = parse_readelf(run(["readelf", "-wF", path]))

    problems = []
    kinds = collections.Counter()
    rows = 0
    bad = 0
    for a, b in zip(ours, theirs):
        if (a[0], a[1]) != (b[0], b[1]):
            problems.append(f"range {a[0]:x}..{a[1]:x}, readelf has {b[0]:x}..{b[1]:x}")
            kinds["function range"] += 1
            bad += 1
            continue
        if a[3]:
            problems.append(f"{a[0]:x}..{a[1]:x}: unwind-dump could not read it ({a[3]})")
            kinds["could not read"] += 1
            bad += 1
            continue
        rows += len(b[2])
        d = diff_rows(a[2], b[2])
        if d:
            bad += 1
            kinds[d[0]] += 1
            problems.append(f"{a[0]:x}..{a[1]:x}: {d[1]}")
    
    problems.sort(key=lambda p: "rows, readelf has" in p)  # real differences first

    print(f"{path}: {len(ours)} functions from unwind-dump, {len(theirs)} from readelf, "
          f"{rows} rows compared, {bad} functions differ")
    if kinds:
        print("  by kind: " + ", ".join(f"{k}: {n}" for k, n in kinds.most_common()))
    for p in problems[:15]:
        print("  " + p)
    sys.exit(1 if bad or len(ours) != len(theirs) else 0)


main()
