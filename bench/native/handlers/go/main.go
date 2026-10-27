// H2: n calls of a counter's Bump, through an interface, as a Go program
// injects a dependency; next to the same loop calling a plain function.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type counter interface {
	Bump(k int) int
}

// adds up what it's given, and says the total so far
type total struct {
	total int
}

func (t *total) Bump(k int) int {
	t.total += k
	return t.total
}

func countWithHandler(c counter, n int) int {
	last := 0
	for i := 0; i < n; i++ {
		last = c.Bump(i % 7)
	}
	return last
}

func bump(total, k int) int {
	return total + k
}

func countWithFunction(n int) int {
	total := 0
	for i := 0; i < n; i++ {
		total = bump(total, i%7)
	}
	return total
}

func main() {
	n := 1000000000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	fmt.Println(countWithHandler(&total{}, n))
	fmt.Println(countWithFunction(n))
}
