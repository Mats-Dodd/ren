// Every way to put n queens on an n by n board: Koka's nqueens
// benchmark (test/bench/koka/nqueens.kk). Solutions share their tails.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type list struct {
	head int
	tail *list
}

type lists struct {
	head *list
	tail *lists
}

func safe(queen, diag int, xs *list) bool {
	for ; xs != nil; xs = xs.tail {
		q := xs.head
		if queen == q || queen == q+diag || queen == q-diag {
			return false
		}
		diag++
	}
	return true
}

func appendSafe(queen int, xs *list, xss *lists) *lists {
	for ; queen > 0; queen-- {
		if safe(queen, 1, xs) {
			xss = &lists{&list{queen, xs}, xss}
		}
	}
	return xss
}

func findSolutions(n, queen int) *lists {
	if queen == 0 {
		return &lists{nil, nil}
	}
	var acc *lists
	for cur := findSolutions(n, queen-1); cur != nil; cur = cur.tail {
		acc = appendSafe(n, cur.head, acc)
	}
	return acc
}

func main() {
	n := 13
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	count := 0
	for xss := findSolutions(n, n); xss != nil; xss = xss.tail {
		count++
	}
	fmt.Println(count)
}
