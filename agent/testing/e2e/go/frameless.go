// A Go program for the agent's end-to-end tests (testing/e2e/go_unwind.zig).
//
// leaf has no stack frame: it never pushes rbp. A sample inside it, walked by frame pointers,
// reads middle's rbp and skips middle. With the pclntab table, middle must be its caller.
package main

var sink int

//go:noinline
func leaf(x int) int { return x*3 + 1 }

//go:noinline
func middle(n int) int {
	var buf [16]int
	for i := range buf {
		buf[i] = leaf(i + n)
	}
	return buf[n%16]
}

func main() {
	for i := 0; ; i++ {
		sink += middle(i)
	}
}
