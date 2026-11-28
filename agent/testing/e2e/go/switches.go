package main

import "time"

var sink int64

//go:noinline
func deep(n int) int64 {
	var pad [512]byte
	pad[n%512] = byte(n)
	if n == 0 {
		return int64(pad[0])
	}
	return deep(n-1) + int64(pad[n%512])
}

//go:noinline
func clock() {
	sink += time.Now().UnixNano() & 1
}

func work(done chan bool) {
	for i := 0; i < 200; i++ {
		clock()
	}
	sink += deep(64)
	done <- true
}

// Reads the clock, and grows a fresh goroutine's stack, again and again: both switch to
// Go's system stack.
func main() {
	for {
		done := make(chan bool)
		go work(done)
		<-done
	}
}
