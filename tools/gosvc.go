// A test service with known performance problems, to check the numbers a profiler gives.
// Workers run jobs of different kinds in fixed proportions. Every job is timed with the CPU
// clock of its own thread. Workers never block and are locked to one thread, so that is exact.
// The totals are the ground truth to compare a profiler with.
//
//	SIGUSR1  starts the measured window (and the pprof profile, if asked for)
//	SIGUSR2  ends it and prints the results
//	SIGINT   exits
package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"regexp"
	"runtime"
	"runtime/pprof"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

type rng struct{ s uint64 }

func (r *rng) next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s
}

// threadCPU is the CPU time this OS thread has used so far, in nanoseconds.
func threadCPU() int64 {
	var ts syscall.Timespec
	syscall.Syscall(syscall.SYS_CLOCK_GETTIME, 3, uintptr(unsafe.Pointer(&ts)), 0) // 3 is CLOCK_THREAD_CPUTIME_ID
	return ts.Nano()
}

// processCPU is the CPU time all threads of this process have used so far, in nanoseconds.
func processCPU() int64 {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return ru.Utime.Nano() + ru.Stime.Nano()
}

var sink atomic.Uint64

// ---- the jobs. Each has a known problem. They are not inlined, so the profile shows them.

//go:noinline
func less(a, b int) bool { return a < b }

//go:noinline
func insertionSort(a []int) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && less(a[j], a[j-1]); j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

// Problem: an O(n^2) sort where sort.Ints would do.
//
//go:noinline
func jobSlowSort(r *rng) {
	a := make([]int, 2500)
	for i := range a {
		a[i] = int(r.next() % 100000)
	}
	insertionSort(a)
	sink.Add(uint64(a[0]))
}

// Problem: the regular expression is compiled again on every use.
//
//go:noinline
func jobRegex(r *rng) {
	for i := 0; i < 30; i++ {
		re := regexp.MustCompile(`^([a-z]+)-(\d{1,5})@([a-z0-9.]+)\.(com|org|net)$`)
		if re.MatchString("someone-4821@example.org") {
			sink.Add(1)
		}
	}
}

type item struct {
	ID     int      `json:"id"`
	Name   string   `json:"name"`
	Tags   []string `json:"tags"`
	Score  float64  `json:"score"`
	Nested *item    `json:"nested,omitempty"`
}

func buildItem(depth, id int) *item {
	it := &item{ID: id, Name: fmt.Sprintf("item-%d", id), Tags: []string{"alpha", "beta", "gamma"}, Score: float64(id) * 1.5}
	if depth > 0 {
		it.Nested = buildItem(depth-1, id+1)
	}
	return it
}

// Problem: the same value is encoded again and again, through reflection.
//
//go:noinline
func jobJSON(r *rng) {
	it := buildItem(6, int(r.next()%1000))
	for i := 0; i < 20; i++ {
		b, err := json.Marshal(it)
		if err != nil {
			panic(err)
		}
		sink.Add(uint64(len(b)))
	}
}

var hashBuf = make([]byte, 64*1024)

// Problem: hashing the same large buffer repeatedly.
//
//go:noinline
func jobHash(r *rng) {
	for i := 0; i < 30; i++ {
		hashBuf[0] = byte(i)
		sum := sha256.Sum256(hashBuf)
		sink.Add(uint64(sum[0]))
	}
}

// Problem: thousands of tiny system calls where one would do. Mostly kernel time.
//
//go:noinline
func jobSyscalls(r *rng) {
	for i := 0; i < 20000; i++ {
		sink.Add(uint64(syscall.Getpid()))
	}
}

// Problem: none for the CPU. This waits, so it must show as about 0% of the CPU.
//
//go:noinline
func jobSleep(r *rng) {
	time.Sleep(3 * time.Millisecond)
}

// Problem: lots of short-lived garbage. The garbage collector's CPU runs on other threads
// and belongs to no job.
//
//go:noinline
func jobAlloc(r *rng) {
	keep := make([][]byte, 0, 256)
	for i := 0; i < 20000; i++ {
		b := make([]byte, 64+int(r.next()%512))
		b[0] = byte(i)
		if i%100 == 0 {
			keep = append(keep, b)
		}
	}
	sink.Add(uint64(len(keep)))
}

//go:noinline
func deepWork(r *rng) uint64 {
	var x uint64
	for i := 0; i < 200000; i++ {
		x = x*6364136223846793005 + r.next()
	}
	return x
}

//go:noinline
func recurse(n int, r *rng) uint64 {
	if n == 0 {
		return deepWork(r)
	}
	return recurse(n-1, r) + 1
}

// Problem: 200 nested calls, more frames than the agent keeps (127).
//
//go:noinline
func jobDeep(r *rng) {
	sink.Add(recurse(200, r))
}

// ---- the schedule and the measuring

const (
	jSort = iota
	jRegex
	jJSON
	jHash
	jSyscalls
	jSleep
	jAlloc
	jDeep
	numJobs
)

type job struct {
	name string // as the report names it
	fn   string // as a profile shows its entry function
	run  func(*rng)
}

var jobs = [numJobs]job{
	jSort:     {"slowSort", "main.jobSlowSort", jobSlowSort},
	jRegex:    {"regexCompile", "main.jobRegex", jobRegex},
	jJSON:     {"jsonEncode", "main.jobJSON", jobJSON},
	jHash:     {"hashLoop", "main.jobHash", jobHash},
	jSyscalls: {"syscalls", "main.jobSyscalls", jobSyscalls},
	jSleep:    {"sleepWait", "main.jobSleep", jobSleep},
	jAlloc:    {"allocHeavy", "main.jobAlloc", jobAlloc},
	jDeep:     {"deepRecursion", "main.jobDeep", jobDeep},
}

// What a worker runs, one after the other.
var schedule = []int{jSort, jSort, jSort, jRegex, jRegex, jJSON, jJSON, jHash, jSyscalls, jSleep, jAlloc, jDeep}

var (
	calls [numJobs]atomic.Int64
	cpuNs [numJobs]atomic.Int64
)

func worker(seed uint64) {
	runtime.LockOSThread()
	r := &rng{s: seed*2654435761 + 88172645463325252}
	for i := 0; ; i++ {
		k := schedule[i%len(schedule)]
		start := threadCPU()
		jobs[k].run(r)
		spent := threadCPU() - start
		calls[k].Add(1)
		cpuNs[k].Add(spent)
	}
}

type jobResult struct {
	Name  string  `json:"name"`
	Func  string  `json:"func"`
	Calls int64   `json:"calls"`
	CPUS  float64 `json:"cpu_s"`
}

type result struct {
	WallS       float64     `json:"wall_s"`
	ProcessCPUS float64     `json:"process_cpu_s"`
	Jobs        []jobResult `json:"jobs"`
}

var (
	t0      time.Time
	cpu0    int64
	profile *os.File
)

func startWindow(cpuprofile string) {
	if profile != nil {
		pprof.StopCPUProfile()
		profile.Close()
		profile = nil
	}
	for k := range jobs {
		calls[k].Store(0)
		cpuNs[k].Store(0)
	}
	t0 = time.Now()
	cpu0 = processCPU()
	if cpuprofile != "" {
		f, err := os.Create(cpuprofile)
		if err != nil {
			fmt.Println("cannot write the pprof profile:", err)
		} else {
			profile = f
			pprof.StartCPUProfile(f)
		}
	}
	fmt.Println("window started")
}

func endWindow(out string) {
	wall := time.Since(t0).Seconds()
	proc := float64(processCPU()-cpu0) / 1e9
	if profile != nil {
		pprof.StopCPUProfile()
		profile.Close()
		profile = nil
	}

	res := result{WallS: wall, ProcessCPUS: proc}
	inJobs := 0.0
	fmt.Printf("\nwindow: %.2f s wall, %.2f s of process CPU (%.2f CPUs busy)\n\n", wall, proc, proc/wall)
	fmt.Printf("%-14s %-18s %8s %10s %8s\n", "job", "entry function", "calls", "cpu ms", "% of cpu")
	for k := range jobs {
		cpu := float64(cpuNs[k].Load()) / 1e9
		inJobs += cpu
		res.Jobs = append(res.Jobs, jobResult{jobs[k].name, jobs[k].fn, calls[k].Load(), cpu})
		fmt.Printf("%-14s %-18s %8d %10.0f %7.2f%%\n", jobs[k].name, jobs[k].fn, calls[k].Load(), cpu*1000, 100*cpu/proc)
	}
	fmt.Printf("%-14s %-18s %8s %10.0f %7.2f%%\n", "(not in a job)", "GC, runtime", "", (proc-inJobs)*1000, 100*(proc-inJobs)/proc)

	if out != "" {
		data, _ := json.MarshalIndent(res, "", "  ")
		if err := os.WriteFile(out, data, 0o644); err != nil {
			fmt.Println("cannot write the results:", err)
		}
	}
}

func main() {
	workers := flag.Int("workers", 4, "worker threads, each keeps one CPU busy")
	cpuprofile := flag.String("cpuprofile", "", "write a pprof CPU profile of the measured window here")
	out := flag.String("out", "", "write the results of the measured window here, as JSON")
	flag.Parse()

	for i := 0; i < *workers; i++ {
		go worker(uint64(i + 1))
	}
	fmt.Printf("pid %d, %d workers. SIGUSR1 starts the window, SIGUSR2 ends it, SIGINT exits.\n", os.Getpid(), *workers)

	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs, syscall.SIGUSR1, syscall.SIGUSR2, syscall.SIGINT, syscall.SIGTERM)
	for s := range sigs {
		switch s {
		case syscall.SIGUSR1:
			startWindow(*cpuprofile)
		case syscall.SIGUSR2:
			endWindow(*out)
		default:
			os.Exit(0)
		}
	}
}
