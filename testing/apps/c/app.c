// A C app with a known CPU profile, per 100 ms round:
//   50%  run -> hot -> hot_leaf                       a plain loop in one function
//   30%  run -> warm -> recurse x8                    a recursion 8 deep, spinning at the bottom
//   20%  run -> cold -> qsort (libc) -> compare       the stack goes through libc and back

#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define NOINLINE __attribute__((noinline))

static volatile uint64_t sink;

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

NOINLINE static uint64_t hot_leaf(uint64_t until_ns) {
    uint64_t x = 1;
    while (now_ns() < until_ns) {
        for (int i = 0; i < 4096; i++) x = x * 6364136223846793005u + 1442695040888963407u;
    }
    return x;
}

NOINLINE static void hot(uint64_t until_ns) { sink += hot_leaf(until_ns); }

NOINLINE static uint64_t recurse(int depth, uint64_t until_ns) {
    if (depth > 1) return recurse(depth - 1, until_ns) + 1;
    uint64_t x = 3;
    while (now_ns() < until_ns) {
        for (int i = 0; i < 4096; i++) x ^= x << 13, x ^= x >> 7, x ^= x << 17;
    }
    return x;
}

NOINLINE static void warm(uint64_t until_ns) { sink += recurse(8, until_ns); }

static int numbers[2048];

NOINLINE static int compare(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

NOINLINE static void cold(uint64_t until_ns) {
    uint32_t seed = 7;
    while (now_ns() < until_ns) {
        for (int i = 0; i < 2048; i++) numbers[i] = (int)(seed = seed * 1103515245u + 12345u);
        qsort(numbers, 2048, sizeof numbers[0], compare);
    }
    sink += (uint64_t)numbers[0];
}

NOINLINE static void run(uint64_t until_ns) {
    while (now_ns() < until_ns) {
        uint64_t start = now_ns();
        hot(start + 50000000u);
        warm(start + 80000000u);
        cold(start + 100000000u);
    }
}

int main(int argc, char **argv) {
    uint64_t seconds = argc > 1 ? strtoull(argv[1], 0, 10) : 60;
    run(now_ns() + seconds * 1000000000u);
    return sink == 42;
}
