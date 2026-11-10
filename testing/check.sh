#!/bin/sh
# Checks a folded profile against an app's expect.txt.
#   check.sh <stacks.folded> <expect.txt> [seconds]
#
# expect.txt, one check per line:
#   samples  >300           the profile has at least 300 samples
#   complete >95            at least 95% of the samples have their whole stack
#   self  hot_leaf 50       hot_leaf is the running function in 50% of the samples, +-5 points
#   total run      >95      run is on the stack in at least 95% of the samples
#   self  hot_leaf 50 3     the same, +-3 points
#   rate  99                samples per second over the run: 99, +-5%  (one busy thread)
#   rate  99 2              the same, +-2%
#   path  hot;hot_leaf 50   the stack ends in hot, then hot_leaf, in 50% of the samples
#   kernel 40               the stack has a kernel frame in 40% of the samples, +-5 points
#   kernel_named >95        of those, the share whose kernel frames have names

set -eu

folded=$1
expect=$2
seconds=${3:-0}

awk -v expect="$expect" -v seconds="$seconds" '
FNR == NR {
    if (NF == 0) next
    count = $NF + 0
    stack = substr($0, 1, length($0) - length($NF) - 1)
    stacks += 1
    frames_count[stacks] = split(stack, frames, ";")
    for (i = 1; i <= frames_count[stacks]; i++) frame[stacks, i] = frames[i]
    samples_of[stacks] = count
    samples += count
    if (frames[1] == "[incomplete]") stopped += count
    next
}

function is_kernel(name) {
    return name == "[kernel]" || substr(name, length(name) - 3) == "_[k]"
}

function matches(name, want,    n) {
    if (name == want) return 1
    n = length(name) - length(want)
    return n > 0 && substr(name, n) == "." want
}

function share(kind, want,    s, i, found, sum) {
    sum = 0
    for (s = 1; s <= stacks; s++) {
        found = 0
        if (kind == "self") {
            found = matches(frame[s, frames_count[s]], want)
        } else if (kind == "path") {
            found = ends_with(s, want)
        } else if (kind == "kernel") {
            for (i = 1; i <= frames_count[s] && !found; i++) found = is_kernel(frame[s, i])
        } else {
            for (i = 1; i <= frames_count[s] && !found; i++) found = matches(frame[s, i], want)
        }
        if (found) sum += samples_of[s]
    }
    return samples > 0 ? 100 * sum / samples : 0
}

function ends_with(s, path,    wanted, n, i, at) {
    n = split(path, wanted, ";")
    if (n > frames_count[s]) return 0
    for (i = 1; i <= n; i++) {
        at = frames_count[s] - n + i
        if (!matches(frame[s, at], wanted[i])) return 0
    }
    return 1
}

function within(got, expected, tolerance) {
    if (expected ~ /^>/) return got >= substr(expected, 2) + 0
    return got >= expected - tolerance && got <= expected + tolerance
}

function result(ok, what, got, expected) {
    printf "  %s  %-30s %8s  (expected %s)\n", ok ? "pass" : "FAIL", what, got, expected
    if (!ok) failed++
}

{
    sub(/#.*/, "")
    if (NF == 0) next
    kind = $1

    if (kind == "samples") {
        result(within(samples, $2, 0), "samples", samples + 0, $2)
        next
    }
    if (kind == "rate") {
        if (seconds <= 0) {
            result(0, "rate", "?", $2 "/s (no seconds given to check.sh)")
            next
        }
        rate = samples / seconds
        percent = NF >= 3 ? $3 : 5
        ok = rate >= $2 * (1 - percent / 100) && rate <= $2 * (1 + percent / 100)
        result(ok, "samples per second", sprintf("%.1f", rate), $2 " +-" percent "%")
        next
    }
    if (kind == "kernel_named") {
        in_kernel = 0
        named = 0
        for (s = 1; s <= stacks; s++) {
            has_kernel = 0
            has_name = 0
            for (i = 1; i <= frames_count[s]; i++) {
                if (!is_kernel(frame[s, i])) continue
                has_kernel = 1
                if (frame[s, i] != "[kernel]") has_name = 1
            }
            if (has_kernel) in_kernel += samples_of[s]
            if (has_name) named += samples_of[s]
        }
        got = in_kernel > 0 ? 100 * named / in_kernel : 0
        result(within(got, $2, 0), "kernel frames named", sprintf("%.1f%%", got), $2 "%")
        next
    }
    if (kind == "kernel") {
        expected = $2
        tolerance = NF >= 3 ? $3 : 5
        got = share("kernel", "")
        shown = expected ~ /^>/ ? expected "%" : expected "% +-" tolerance
        result(within(got, expected, tolerance), "kernel", sprintf("%.1f%%", got), shown)
        next
    }
    if (kind == "complete") {
        complete = samples > 0 ? 100 * (samples - stopped) / samples : 0
        result(within(complete, $2, 0), "complete stacks", sprintf("%.1f%%", complete), $2 "%")
        next
    }

    want = $2
    expected = $3
    tolerance = NF >= 4 ? $4 : 5
    got = share(kind, want)
    shown = expected ~ /^>/ ? expected "%" : expected "% +-" tolerance
    result(within(got, expected, tolerance), kind " " want, sprintf("%.1f%%", got), shown)
}

END {
    if (failed > 0) { printf "%d check(s) failed\n", failed; exit 1 }
    print "all checks passed"
}
' "$folded" "$expect"
