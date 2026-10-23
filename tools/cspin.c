// A C program with a known call chain, to be built without frame pointers:
// main calls top, top calls mid, mid calls leaf, and leaf does all the work.
// Each function stores its result in a volatile global after the call, so the compiler can
// neither turn a call into a jump nor drop the function.
#include <stdint.h>

static volatile uint64_t g;

__attribute__((noinline)) static uint64_t leaf(uint64_t n) {
    volatile uint64_t x = 0;
    for (uint64_t i = 0; i < n; i++) x = x * 6364136223846793005ULL + i;
    return x;
}

__attribute__((noinline)) static uint64_t mid(uint64_t n) {
    uint64_t r = leaf(n) + 1;
    g = r;
    return r;
}

__attribute__((noinline)) static uint64_t top(uint64_t n) {
    uint64_t r = mid(n) + 2;
    g = r;
    return r;
}

int main(void) {
    for (;;) g = top(100000000);
}
