// A red-black tree, built by inserting n keys: Koka's rbtree benchmark
// (test/bench/koka/rbtree.kk). Each insert changes the tree in place.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type color int

const (
	red color = iota
	black
)

type node struct {
	color       color
	left, right *node
	key         int
	value       bool
}

func isRed(t *node) bool { return t != nil && t.color == red }

// l is the new left child of p
func balanceLeft(l, p *node) *node {
	if isRed(l.left) {
		ll := l.left
		ll.color = black
		p.left = l.right
		p.color = black
		l.right = p
		l.color = red
		return l
	} else if isRed(l.right) {
		lr := l.right
		l.right = lr.left
		l.color = black
		p.left = lr.right
		p.color = black
		lr.left = l
		lr.right = p
		lr.color = red
		return lr
	}
	l.color = red
	p.left = l
	p.color = black
	return p
}

// r is the new right child of p
func balanceRight(p, r *node) *node {
	if isRed(r.left) {
		rl := r.left
		p.right = rl.left
		p.color = black
		r.left = rl.right
		r.color = black
		rl.left = p
		rl.right = r
		rl.color = red
		return rl
	} else if isRed(r.right) {
		rr := r.right
		rr.color = black
		p.right = r.left
		p.color = black
		r.left = p
		r.color = red
		return r
	}
	r.color = red
	p.right = r
	p.color = black
	return p
}

func ins(t *node, k int, v bool) *node {
	if t == nil {
		return &node{color: red, key: k, value: v}
	}
	if k < t.key {
		if t.color == black && isRed(t.left) {
			return balanceLeft(ins(t.left, k, v), t)
		}
		t.left = ins(t.left, k, v)
	} else if k > t.key {
		if t.color == black && isRed(t.right) {
			return balanceRight(t, ins(t.right, k, v))
		}
		t.right = ins(t.right, k, v)
	} else {
		t.value = v
	}
	return t
}

func insert(t *node, k int, v bool) *node {
	t = ins(t, k, v)
	t.color = black
	return t
}

func fold[A any](t *node, acc A, f func(int, bool, A) A) A {
	for t != nil {
		acc = f(t.key, t.value, fold(t.left, acc, f))
		t = t.right
	}
	return acc
}

func main() {
	n := 4200000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	var t *node
	for i := n; i > 0; {
		i--
		t = insert(t, i, i%10 == 0)
	}
	count := fold(t, 0, func(_ int, v bool, r int) int {
		if v {
			return r + 1
		}
		return r
	})
	fmt.Println(count)
}
