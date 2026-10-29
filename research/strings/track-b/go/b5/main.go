// B5 Go twin: `b5 <file> <size>`: utf8.Valid on each piece, as the C bench.
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
	"unicode/utf8"
)

func main() {
	p, _ := os.ReadFile(os.Args[1])
	size, _ := strconv.Atoi(os.Args[2])
	copies := len(p) / size
	reps := (256 << 20) / size
	ok := 0
	t0 := time.Now()
	for r := 0; r < reps; r++ {
		c := r % copies
		if utf8.Valid(p[c*size : (c+1)*size]) {
			ok++
		}
	}
	t := time.Since(t0).Nanoseconds()
	fmt.Printf("ok=%d\ngbps=%.3f\ntotal_ns=%d\n", ok, float64(size*reps)/float64(t), t)
}
