// H1: each kernel written with a func value, next to its twin written as
// a plain loop, as in bench.ren. Go doesn't specialize a function for the
// func it's given, so the func-value versions call through a pointer.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type tree struct {
	left, right *tree
	value       int
}

func build(lo, hi int) *tree {
	if lo >= hi {
		return nil
	}
	mid := (lo + hi) / 2
	return &tree{build(lo, mid), build(mid+1, hi), mid % 1000}
}

func mapInts(xs []int, f func(int) int) []int {
	out := make([]int, 0)
	for _, x := range xs {
		out = append(out, f(x))
	}
	return out
}

func reduceInts(xs []int, init int, f func(int, int) int) int {
	acc := init
	for _, x := range xs {
		acc = f(acc, x)
	}
	return acc
}

func each(xs []int, f func(int)) {
	for _, x := range xs {
		f(x)
	}
}

func foldTree(t *tree, acc int, f func(int, int) int) int {
	if t == nil {
		return acc
	}
	return foldTree(t.right, f(foldTree(t.left, acc, f), t.value), f)
}

func sumTree(t *tree, acc, k int) int {
	if t == nil {
		return acc
	}
	return sumTree(t.right, sumTree(t.left, acc, k)+t.value*k, k)
}

// body until it gives something other than 0, n times at most
func attemptN(n int, body func() int) int {
	result := 0
	for tries := 0; tries < n && result == 0; tries++ {
		result = body()
	}
	return result
}

func mapBlocks(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		ys := mapInts(xs, func(x int) int { return x*k + 1 })
		total += ys[round%len(ys)]
	}
	return total
}

func mapLoop(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		ys := make([]int, 0)
		for _, x := range xs {
			ys = append(ys, x*k+1)
		}
		total += ys[round%len(ys)]
	}
	return total
}

func reduceBlocks(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		total += reduceInts(xs, 0, func(acc, x int) int { return acc + x*k })
	}
	return total
}

func reduceLoop(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		acc := 0
		for _, x := range xs {
			acc += x * k
		}
		total += acc
	}
	return total
}

func eachBlocks(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		each(xs, func(x int) { total += x * k })
	}
	return total
}

func eachLoop(xs []int, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		for _, x := range xs {
			total += x * k
		}
	}
	return total
}

func foldBlocks(t *tree, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		k := round % 4
		total += foldTree(t, 0, func(acc, v int) int { return acc + v*k })
	}
	return total
}

func foldLoop(t *tree, n int) int {
	total := 0
	for round := 0; round < n; round++ {
		total += sumTree(t, 0, round%4)
	}
	return total
}

func attemptBlocks(n int) int {
	total, calls := 0, 0
	for i := 0; i < n*1000; i++ {
		total += attemptN(3, func() int {
			calls++
			return (i + calls) % 3
		})
	}
	return total + calls
}

func attemptLoop(n int) int {
	total, calls := 0, 0
	for i := 0; i < n*1000; i++ {
		result := 0
		for tries := 0; tries < 3 && result == 0; tries++ {
			calls++
			result = (i + calls) % 3
		}
		total += result
	}
	return total + calls
}

func main() {
	n := 100000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	xs := make([]int, 1000)
	for i := range xs {
		xs[i] = i * 7 % 1000
	}
	t := build(0, 1000)
	fmt.Println("map", mapBlocks(xs, n), mapLoop(xs, n))
	fmt.Println("reduce", reduceBlocks(xs, n), reduceLoop(xs, n))
	fmt.Println("each", eachBlocks(xs, n), eachLoop(xs, n))
	fmt.Println("fold", foldBlocks(t, n), foldLoop(t, n))
	fmt.Println("attempt", attemptBlocks(n), attemptLoop(n))
}
