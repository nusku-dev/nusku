// Many different call paths on every CPU, to see what the profiler does when its tables fill.
package main

import "runtime"

//go:noinline
func leaf(n uint64) uint64 {
	var x uint64
	for i := uint64(0); i < n; i++ {
		x = x*6364136223846793005 + i
	}
	return x
}

//go:noinline
func a(d int, r uint64) uint64 { return walk(d-1, r/3) + 1 }

//go:noinline
func b(d int, r uint64) uint64 { return walk(d-1, r/3) + 2 }

//go:noinline
func c(d int, r uint64) uint64 { return walk(d-1, r/3) + 3 }

//go:noinline
func walk(d int, r uint64) uint64 {
	if d == 0 {
		return leaf(200000)
	}
	switch r % 3 {
	case 0:
		return a(d, r)
	case 1:
		return b(d, r)
	}
	return c(d, r)
}

func main2() {
	for i := 0; i < runtime.NumCPU(); i++ {
		go func(seed uint64) {
			var sink uint64
			for {
				seed = seed*6364136223846793005 + 1442695040888963407
				sink += walk(12, seed>>16)
			}
		}(uint64(i + 1))
	}
	select {}
}
