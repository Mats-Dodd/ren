// Arrays of arrays changed where they are, and lists built by
// recursion. The grid is a slice of slices written by index; `map`
// writes each round's values into new slices, as Go's own map loop
// would; the list is built front to back through a pointer to the next
// empty link, and scaled in place, as a good Go programmer writes a
// list too long to recurse over.
package main

import (
	"fmt"
	"os"
	"strconv"
)

const M = 1000003

type List struct {
	head int
	tail *List
}

func gridOf(n int) [][]int {
	g := make([][]int, n)
	for i := range g {
		g[i] = make([]int, n)
		for j := range g[i] {
			g[i][j] = i*n + j
		}
	}
	return g
}

func total(g [][]int) int {
	s := 0
	for _, row := range g {
		for _, x := range row {
			s = (s + x) % M
		}
	}
	return s
}

func grid(rounds int) int {
	g := gridOf(100)
	for r := 0; r < rounds; r++ {
		for i := 0; i < 100; i++ {
			for j := 0; j < 100; j++ {
				g[i][j] = (g[i][j]*31 + i + j + r) % M
			}
		}
	}
	return total(g)
}

func mapRows(rounds int) int {
	g := gridOf(100)
	for r := 0; r < rounds; r++ {
		out := make([][]int, len(g))
		for i, row := range g {
			o := make([]int, len(row))
			for j, x := range row {
				o[j] = (x*7 + r) % M
			}
			out[i] = o
		}
		g = out
	}
	return total(g)
}

func build(n int) *List {
	var head *List
	at := &head
	for i := 0; i < n; i++ {
		c := &List{head: i}
		*at = c
		at = &c.tail
	}
	return head
}

func scale(l *List, k int) *List {
	for c := l; c != nil; c = c.tail {
		c.head = c.head * k % M
	}
	return l
}

func sum(l *List) int {
	s := 0
	for c := l; c != nil; c = c.tail {
		s = (s + c.head) % M
	}
	return s
}

func list(rounds, n int) int {
	s := 0
	for r := 0; r < rounds; r++ {
		s = (s + sum(scale(build(n), r+2))) % M
	}
	return s
}

func main() {
	n := 1000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	fmt.Println(grid(n * 10))
	fmt.Println(mapRows(n * 10))
	fmt.Println(list(n/10+1, 1000*n))
}
