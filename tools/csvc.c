// A C test service with known performance problems, to check the numbers a profiler gives.
// It works like gosvc.go: workers run jobs in fixed proportions, every job is timed with the
// CPU clock of its own thread, and the totals of a measured window are the ground truth.
//
//   SIGUSR1  starts the measured window
//   SIGUSR2  ends it and prints the results (and writes them as JSON with -out)
//   SIGINT   exits
//
// Build without frame pointers, so the unwind tables have to carry the walk:
//   zig cc -O2 -g -fomit-frame-pointer -pthread -o zig-out/bin/nusku-csvc tools/csvc.c
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static _Atomic uint64_t sink;

typedef struct { uint64_t s; } Rng;

static inline uint64_t rng_next(Rng *r) {
    r->s ^= r->s << 13;
    r->s ^= r->s >> 7;
    r->s ^= r->s << 17;
    return r->s;
}

static int64_t clock_ns(clockid_t id) {
    struct timespec ts;
    clock_gettime(id, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

// The CPU time all threads of this process have used so far, in seconds.
static double process_cpu_s(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
}

// ---- the jobs. Each has a known problem. They are not inlined, so the profile shows them.

__attribute__((noinline)) static int less(int a, int b) { return a < b; }

__attribute__((noinline)) static void insertion_sort(int *a, int n) {
    for (int i = 1; i < n; i++) {
        for (int j = i; j > 0 && less(a[j], a[j - 1]); j--) {
            int t = a[j];
            a[j] = a[j - 1];
            a[j - 1] = t;
        }
    }
}

// Problem: an O(n^2) sort where qsort would do.
__attribute__((noinline)) static void job_sort(Rng *r) {
    int a[2500];
    for (int i = 0; i < 2500; i++) a[i] = (int)(rng_next(r) % 100000);
    insertion_sort(a, 2500);
    atomic_fetch_add(&sink, (uint64_t)a[0]);
}

__attribute__((noinline)) static int compare_int(const void *p, const void *q) {
    int x = *(const int *)p, y = *(const int *)q;
    return (x > y) - (x < y);
}

// Problem: sorting through a comparison callback, so libc's frames sit between ours.
__attribute__((noinline)) static void job_qsort(Rng *r) {
    int a[20000];
    for (int i = 0; i < 20000; i++) a[i] = (int)(rng_next(r) % 1000000);
    qsort(a, 20000, sizeof a[0], compare_int);
    atomic_fetch_add(&sink, (uint64_t)a[0]);
}

// Problem: copying a large buffer again and again.
__attribute__((noinline)) static void job_memcpy(Rng *r) {
    unsigned char src[262144], dst[262144];
    memset(src, (int)(rng_next(r) & 0xff), sizeof src);
    for (int i = 0; i < 80; i++) {
        memcpy(dst, src, sizeof src);
        __asm__ volatile("" : : "r"(dst) : "memory");
        src[i] = dst[i * 100];
    }
    atomic_fetch_add(&sink, dst[0]);
}

// Problem: thousands of tiny system calls where one would do. Mostly kernel time.
__attribute__((noinline)) static void job_syscalls(Rng *r) {
    (void)r;
    for (int i = 0; i < 20000; i++) atomic_fetch_add(&sink, (uint64_t)syscall(SYS_getpid));
}

// Problem: none for the CPU. This waits, so it must show as about 0% of the CPU.
__attribute__((noinline)) static void job_sleep(Rng *r) {
    (void)r;
    struct timespec ts = {0, 3000000};
    nanosleep(&ts, NULL);
}

// ---- the schedule and the measuring

typedef void (*JobFn)(Rng *);
typedef struct {
    const char *name;
    const char *func; // as a profile shows its entry function
    JobFn run;
} Job;

static const Job jobs[] = {
    {"slowSort", "job_sort", job_sort},
    {"qsortCallback", "job_qsort", job_qsort},
    {"memcpyLoop", "job_memcpy", job_memcpy},
    {"syscalls", "job_syscalls", job_syscalls},
    {"sleepWait", "job_sleep", job_sleep},
};
#define NJOBS (sizeof jobs / sizeof jobs[0])

// What a worker runs, one after the other (indexes into `jobs`).
static const int schedule[] = {0, 0, 0, 1, 1, 2, 2, 3, 4};

static _Atomic uint64_t job_calls[NJOBS];
static _Atomic uint64_t job_ns[NJOBS];

static void *worker(void *arg) {
    Rng r = {(uint64_t)(uintptr_t)arg * 2654435761u + 88172645463325252ull};
    size_t n = sizeof schedule / sizeof schedule[0];
    for (size_t i = 0;; i++) {
        int k = schedule[i % n];
        int64_t start = clock_ns(CLOCK_THREAD_CPUTIME_ID);
        jobs[k].run(&r);
        int64_t spent = clock_ns(CLOCK_THREAD_CPUTIME_ID) - start;
        atomic_fetch_add(&job_calls[k], 1);
        atomic_fetch_add(&job_ns[k], (uint64_t)spent);
    }
    return NULL;
}

static int64_t window_start_ns;
static double window_start_cpu;

static void start_window(void) {
    for (size_t k = 0; k < NJOBS; k++) {
        atomic_store(&job_calls[k], 0);
        atomic_store(&job_ns[k], 0);
    }
    window_start_ns = clock_ns(CLOCK_MONOTONIC);
    window_start_cpu = process_cpu_s();
    puts("window started");
    fflush(stdout);
}

static void end_window(const char *out) {
    double wall = (double)(clock_ns(CLOCK_MONOTONIC) - window_start_ns) / 1e9;
    double proc = process_cpu_s() - window_start_cpu;
    double in_jobs = 0;

    printf("\nwindow: %.2f s wall, %.2f s of process CPU (%.2f CPUs busy)\n\n", wall, proc, proc / wall);
    printf("%-14s %-18s %8s %10s %8s\n", "job", "entry function", "calls", "cpu ms", "% of cpu");
    for (size_t k = 0; k < NJOBS; k++) {
        double cpu = (double)atomic_load(&job_ns[k]) / 1e9;
        in_jobs += cpu;
        printf("%-14s %-18s %8llu %10.0f %7.2f%%\n", jobs[k].name, jobs[k].func,
               (unsigned long long)atomic_load(&job_calls[k]), cpu * 1000, 100 * cpu / proc);
    }
    printf("%-14s %-18s %8s %10.0f %7.2f%%\n", "(not in a job)", "runtime", "", (proc - in_jobs) * 1000,
           100 * (proc - in_jobs) / proc);
    fflush(stdout);

    if (out) {
        FILE *f = fopen(out, "w");
        if (!f) {
            puts("cannot write the results");
            fflush(stdout);
            return;
        }
        fprintf(f, "{\n  \"wall_s\": %.6f,\n  \"process_cpu_s\": %.6f,\n  \"jobs\": [\n", wall, proc);
        for (size_t k = 0; k < NJOBS; k++) {
            fprintf(f, "    {\"name\": \"%s\", \"func\": \"%s\", \"calls\": %llu, \"cpu_s\": %.6f}%s\n", jobs[k].name,
                    jobs[k].func, (unsigned long long)atomic_load(&job_calls[k]),
                    (double)atomic_load(&job_ns[k]) / 1e9, k + 1 < NJOBS ? "," : "");
        }
        fprintf(f, "  ]\n}\n");
        fclose(f);
    }
}

int main(int argc, char **argv) {
    int workers = 4;
    const char *out = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-workers") && i + 1 < argc) workers = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-out") && i + 1 < argc) out = argv[++i];
    }

    // Block the signals before the workers start, so only this thread receives them.
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    sigaddset(&set, SIGUSR2);
    sigaddset(&set, SIGINT);
    sigaddset(&set, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &set, NULL);

    for (int i = 0; i < workers; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, worker, (void *)(uintptr_t)(i + 1)) != 0) {
            perror("pthread_create");
            return 1;
        }
    }
    printf("pid %d, %d workers. SIGUSR1 starts the window, SIGUSR2 ends it, SIGINT exits.\n", getpid(), workers);
    fflush(stdout);

    for (;;) {
        int sig = 0;
        sigwait(&set, &sig);
        if (sig == SIGUSR1) start_window();
        else if (sig == SIGUSR2) end_window(out);
        else exit(0);
    }
}
