// H5: a kernel over two slices it changes and one it reads, in a loop.
// Go can't know the slices don't overlap.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func step(a, b, c []int) {
	for i := range a {
		a[i] = (a[i] + b[i]*c[i]) % 65536
		b[i] = (b[i] + a[i]) % 65536
	}
}

func main() {
	n := 2000000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	a := make([]int, 1000)
	b := make([]int, 1000)
	c := make([]int, 1000)
	for i := range a {
		a[i] = i
		b[i] = 1000 - i
		c[i] = i % 13
	}
	for r := 0; r < n; r++ {
		step(a, b, c)
	}
	sum := 0
	for i := range a {
		sum += a[i] + b[i]
	}
	fmt.Println(sum)
}
