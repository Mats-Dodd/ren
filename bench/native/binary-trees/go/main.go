// Binary trees, from the Benchmarks Game, on one thread: many perfect
// trees made and dropped at each depth, while one long-lived tree stays.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type tree struct {
	left, right *tree
}

// a perfect tree depth deep; a tip is nil
func make_(depth int) *tree {
	if depth > 0 {
		return &tree{make_(depth - 1), make_(depth - 1)}
	}
	return &tree{}
}

// how many nodes it has
func check(t *tree) int {
	if t.left == nil {
		return 1
	}
	return check(t.left) + check(t.right) + 1
}

func main() {
	n := 21
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	minDepth := 4
	maxDepth := max(n, minDepth+2)
	stretch := maxDepth + 1
	fmt.Printf("stretch tree of depth %d\t check: %d\n", stretch, check(make_(stretch)))
	long := make_(maxDepth)
	for depth := minDepth; depth <= maxDepth; depth += 2 {
		iterations := 1 << (maxDepth - depth + minDepth)
		total := 0
		for i := 0; i < iterations; i++ {
			total += check(make_(depth))
		}
		fmt.Printf("%d\t trees of depth %d\t check: %d\n", iterations, depth, total)
	}
	fmt.Printf("long lived tree of depth %d\t check: %d\n", maxDepth, check(long))
}
