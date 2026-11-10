// Threads with a known CPU profile:
//   main thread    spin_main -> spin            busy all the time            1.0 core
//   one thread     half_main -> half_work       busy 50 ms, asleep 50 ms     0.5 core
//   one thread     read_main -> read_work       reads /dev/zero: the kernel  1.0 core
//                  -> read (libc) -> kernel     fills the buffer
//   one thread     sleep_main                   asleep all the time          0.0 core
// 2.5 cores: 247.5 samples a second at 99 Hz.

#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define NOINLINE __attribute__((noinline))

static volatile uint64_t sink;
static uint64_t until_ns;

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void sleep_ms(uint64_t ms) {
    struct timespec t = {.tv_sec = (time_t)(ms / 1000), .tv_nsec = (long)(ms % 1000) * 1000000};
    nanosleep(&t, 0);
}

NOINLINE static uint64_t busy_until(uint64_t end_ns) {
    uint64_t x = 1;
    while (now_ns() < end_ns) {
        for (int i = 0; i < 4096; i++) x = x * 6364136223846793005u + 1442695040888963407u;
    }
    return x;
}

NOINLINE static void spin(void) { sink += busy_until(until_ns); }

NOINLINE static void spin_main(void) { spin(); }

NOINLINE static void half_work(uint64_t end_ns) { sink += busy_until(end_ns); }

NOINLINE static void *half_main(void *unused) {
    (void)unused;
    while (now_ns() < until_ns) {
        uint64_t start = now_ns();
        half_work(start + 50000000u);
        sleep_ms(50);
    }
    return 0;
}

static char buffer[1 << 20];

NOINLINE static void read_work(int fd) {
    if (read(fd, buffer, sizeof buffer) < 0) abort();
}

NOINLINE static void *read_main(void *unused) {
    (void)unused;
    int fd = open("/dev/zero", O_RDONLY);
    if (fd < 0) abort();
    while (now_ns() < until_ns) read_work(fd);
    close(fd);
    return 0;
}

NOINLINE static void *sleep_main(void *unused) {
    (void)unused;
    while (now_ns() < until_ns) sleep_ms(100);
    return 0;
}

int main(int argc, char **argv) {
    uint64_t seconds = argc > 1 ? strtoull(argv[1], 0, 10) : 60;
    until_ns = now_ns() + seconds * 1000000000u;

    pthread_t threads[3];
    pthread_create(&threads[0], 0, half_main, 0);
    pthread_create(&threads[1], 0, read_main, 0);
    pthread_create(&threads[2], 0, sleep_main, 0);
    spin_main();
    for (int i = 0; i < 3; i++) pthread_join(threads[i], 0);
    return sink == 42;
}
