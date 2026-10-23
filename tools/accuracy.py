#!/usr/bin/env python3
"""Compares what nusku measured for the test service with what the service measured itself.

Usage: accuracy.py ORACLE.json NUSKU_OUTPUT.txt
"""
import collections
import json
import re
import sys

HZ = 99  # samples per second on each CPU, as the agent sets it

oracle = json.load(open(sys.argv[1]))
header = re.compile(r"^pid \d+\s+window (\d+) ms\s+(\d+) samples in (\d+) stacks")
lost_re = re.compile(r"^\s+lost: dropped (\d+), map full (\d+), held back (\d+), bad records (\d+)")
incomplete_re = re.compile(r"^\s+incomplete stacks: (\d+) of (\d+) samples \(([\d.]+)%\)(?::(.*))?$")

total_samples = 0
total_ms = 0
windows = 0
lost = collections.Counter()
cut_by = collections.Counter()  # reason the walk stopped -> samples
cut_total = 0
user = collections.defaultdict(lambda: [0, 0])  # name -> [self, total] samples
kernel = collections.defaultdict(lambda: [0, 0])

for line in open(sys.argv[2], errors="replace"):
    line = line.rstrip("\n")
    m = header.match(line)
    if m:
        windows += 1
        total_ms += int(m.group(1))
        total_samples += int(m.group(2))
        continue
    m = lost_re.match(line)
    if m:
        for key, value in zip(("dropped", "map_full", "held_back", "bad_records"), m.groups()):
            lost[key] += int(value)
        continue
    m = incomplete_re.match(line)
    if m:
        cut_total += int(m.group(1))
        for name, n in re.findall(r"(\w+) (\d+)", m.group(4) or ""):
            cut_by[name] += int(n)
        continue    
    if line.startswith("F\t"):
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        kind, name = parts[4], parts[5]
        table = kernel if kind == "k" else user
        table[name][0] += int(parts[2])
        table[name][1] += int(parts[3])

if total_samples == 0:
    sys.exit("no samples found in " + sys.argv[2])

seconds = total_ms / 1000
nusku_rate = total_samples / HZ / seconds
oracle_rate = oracle["process_cpu_s"] / oracle["wall_s"]
print(f"\nnusku: {windows} windows, {seconds:.1f} s, {total_samples} samples")
print(f"busy CPUs: nusku {nusku_rate:.3f}, the service's own clock {oracle_rate:.3f} "
      f"({100 * (nusku_rate / oracle_rate - 1):+.1f}%)")
print(f"samples lost before they were counted: dropped {lost['dropped']}, map full {lost['map_full']}, "
      f"held back {lost['held_back']}, bad records {lost['bad_records']}")
print(f"incomplete stacks: {cut_total} of {total_samples} samples ({100 * cut_total / total_samples:.2f}%)")
for name, n in cut_by.most_common():
    print(f"  {name:<20} {n:>8}  {100 * n / total_samples:6.2f}%")
in_some_function = sum(v[0] for v in user.values()) + sum(v[0] for v in kernel.values())
print(f"samples inside some function: {in_some_function} of {total_samples} "
      f"({100 * in_some_function / total_samples:.2f}%)")

print(f"\n{'job':<14} {'entry function':<18} {'service %':>9} {'nusku %':>8} {'diff':>7}  verdict")
for j in oracle["jobs"]:
    want = 100 * j["cpu_s"] / oracle["process_cpu_s"]
    got = 100 * user.get(j["func"], [0, 0])[1] / total_samples
    tol = 1.0 if want >= 2 else 0.3
    verdict = "ok" if abs(got - want) <= tol else f"WRONG (limit +-{tol})"
    print(f"{j['name']:<14} {j['func']:<18} {want:9.2f} {got:8.2f} {got - want:+7.2f}  {verdict}")

# What pprof measured for this service in the earlier run, as a share of all CPU.
pprof = {
    "main.insertionSort": 42.42,
    "main.less": 6.43,
    "main.recurse": 1.69,
    "crypto/sha256.Sum256": 20.35,
    "syscall.Getpid": 7.74,
}
print(f"\n{'function':<24} {'self %':>7} {'total %':>8} {'pprof total %':>14}")
for name, ref in pprof.items():
    s, t = user.get(name, [0, 0])
    print(f"{name:<24} {100 * s / total_samples:7.2f} {100 * t / total_samples:8.2f} {ref:14.2f}")

print("\nkernel functions by self time:")
for name, (s, t) in sorted(kernel.items(), key=lambda kv: -kv[1][0])[:8]:
    print(f"  {name:<36} self {100 * s / total_samples:5.2f}%  total {100 * t / total_samples:5.2f}%")

print("\nuser functions by self time:")
for name, (s, t) in sorted(user.items(), key=lambda kv: -kv[1][0])[:14]:
    print(f"  {name:<46} self {100 * s / total_samples:5.2f}%  total {100 * t / total_samples:5.2f}%")
