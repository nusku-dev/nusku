// A Go app with a known CPU profile, per 100 ms round:
//	50%  run -> hot -> hotLeaf                         a plain loop in one function
//	30%  run -> warm -> recurse x8                     a recursion 8 deep, spinning at the bottom
//	20%  run -> cold -> sort.Slice -> the less closure  the stack goes through the runtime and back
package main

import (
	"os"
	"sort"
	"strconv"
	"time"
)

var sink uint64

//go:noinline
func hotLeaf(until time.Time) uint64 {
	x := uint64(1)
	for time.Now().Before(until) {
		for i := 0; i < 4096; i++ {
			x = x*6364136223846793005 + 1442695040888963407
		}
	}
	return x
}

//go:noinline
func hot(until time.Time) { sink += hotLeaf(until) }

//go:noinline
func recurse(depth int, until time.Time) uint64 {
	if depth > 1 {
		return recurse(depth-1, until) + 1
	}
	x := uint64(3)
	for time.Now().Before(until) {
		for i := 0; i < 4096; i++ {
			x ^= x << 13
			x ^= x >> 7
			x ^= x << 17
		}
	}
	return x
}

//go:noinline
func warm(until time.Time) { sink += recurse(8, until) }

var numbers = make([]int, 2048)

//go:noinline
func cold(until time.Time) {
	seed := uint32(7)
	for time.Now().Before(until) {
		for i := range numbers {
			seed = seed*1103515245 + 12345
			numbers[i] = int(int32(seed))
		}
		sort.Slice(numbers, func(a, b int) bool { return numbers[a] < numbers[b] })
	}
	sink += uint64(numbers[0])
}

//go:noinline
func run(until time.Time) {
	for time.Now().Before(until) {
		start := time.Now()
		hot(start.Add(50 * time.Millisecond))
		warm(start.Add(80 * time.Millisecond))
		cold(start.Add(100 * time.Millisecond))
	}
}

func main() {
	seconds := 60
	if len(os.Args) > 1 {
		seconds, _ = strconv.Atoi(os.Args[1])
	}
	run(time.Now().Add(time.Duration(seconds) * time.Second))
	if sink == 42 {
		os.Exit(1)
	}
}
