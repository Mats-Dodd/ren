// H8's kernels: a small object built, used and dropped each round. Go's
// escape analysis keeps each one on the stack.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type line struct {
	item  string
	qty   int
	cents int
}

func subtotal(l *line) int { return l.qty*l.cents + len(l.item) }

func records(items []string, n int) int {
	sum := 0
	for i := 0; i < n; i++ {
		l := line{items[i%len(items)], i % 7, i % 13}
		sum = (sum + subtotal(&l)) % 1_000_000_007
	}
	return sum
}

func priceOf(i int) (int, bool) {
	if i%3 == 0 {
		return 0, false
	}
	return i % 101, true
}

func options(n int) int {
	sum := 0
	for i := 0; i < n; i++ {
		if p, ok := priceOf(i); ok {
			sum = (sum + p) % 1_000_000_007
		} else {
			sum = (sum + 1) % 1_000_000_007
		}
	}
	return sum
}

func pick(items []string, i int) (string, int) { return items[i%len(items)], i % 1000 }

func tuples(items []string, n int) int {
	sum := 0
	for i := 0; i < n; i++ {
		s, k := pick(items, i)
		sum = (sum + len(s) + k) % 1_000_000_007
	}
	return sum
}

func withLine(l *line, f func(*line) int) int { return f(l) }

func blocks(items []string, n int) int {
	sum := 0
	markup := 3
	for i := 0; i < n; i++ {
		l := line{items[i%len(items)], i % 5, i % 11}
		sum = (sum + withLine(&l, func(x *line) int { return x.qty*x.cents*markup + len(x.item) })) % 1_000_000_007
	}
	return sum
}

func main() {
	n := 50_000_000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	kernel := ""
	if len(os.Args) > 2 {
		kernel = os.Args[2]
	}
	items := []string{"apple", "pear", "fig", "quince"}
	if kernel == "" || kernel == "records" {
		fmt.Println(records(items, n))
	}
	if kernel == "" || kernel == "options" {
		fmt.Println(options(n))
	}
	if kernel == "" || kernel == "tuples" {
		fmt.Println(tuples(items, n))
	}
	if kernel == "" || kernel == "blocks" {
		fmt.Println(blocks(items, n))
	}
}
