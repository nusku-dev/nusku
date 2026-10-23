// A C program with a known call chain, to be built without frame pointers:
// main calls top, top calls mid, mid calls leaf, and leaf does all the work.
#include <stdint.h>

__attribute__((noinline)) static uint64_t leaf(uint64_t n) {
    volatile uint64_t x = 0;
    for (uint64_t i = 0; i < n; i++) x = x * 6364136223846793005ULL + i;
    return x;
}

__attribute__((noinline)) static uint64_t mid(uint64_t n) { return leaf(n) + 1; }

__attribute__((noinline)) static uint64_t top(uint64_t n) { return mid(n) + 2; }

int main(void) {
    uint64_t sink = 0;
    for (;;) sink += top(100000000);
}
