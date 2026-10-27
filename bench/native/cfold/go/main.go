// Constant folding: Koka's cfold benchmark (test/bench/koka/cfold.kk).
// Each pass builds a new tree from the one it's given.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type kind int

const (
	kVar kind = iota
	kVal
	kAdd
	kMul
)

type expr struct {
	kind kind
	val  int // a Var's name, or a Val's value
	l, r *expr
}

func leaf(k kind, v int) *expr     { return &expr{kind: k, val: v} }
func bin(k kind, l, r *expr) *expr { return &expr{kind: k, l: l, r: r} }

func mkExpr(n, v int) *expr {
	if n == 0 {
		if v == 0 {
			return leaf(kVar, 1)
		}
		return leaf(kVal, v)
	}
	w := 0
	if v > 1 {
		w = v - 1
	}
	return bin(kAdd, mkExpr(n-1, v+1), mkExpr(n-1, w))
}

// e0 and e3 joined by `k`, down e0's right side if it's a `k` already
func appendOp(k kind, e0, e3 *expr) *expr {
	if e0.kind == k {
		return bin(k, e0.l, appendOp(k, e0.r, e3))
	}
	return bin(k, e0, e3)
}

func reassoc(e *expr) *expr {
	if e.kind == kAdd || e.kind == kMul {
		return appendOp(e.kind, reassoc(e.l), reassoc(e.r))
	}
	return e
}

func apply(k kind, x, y int) int {
	if k == kAdd {
		return x + y
	}
	return x * y
}

func cfold(e *expr) *expr {
	if e.kind != kAdd && e.kind != kMul {
		return e
	}
	k := e.kind
	a := cfold(e.l)
	b := cfold(e.r)
	if a.kind == kVal {
		switch {
		case b.kind == kVal:
			return leaf(kVal, apply(k, a.val, b.val))
		case b.kind == k && b.r.kind == kVal:
			return bin(k, leaf(kVal, apply(k, a.val, b.r.val)), b.l)
		case b.kind == k && b.l.kind == kVal:
			return bin(k, leaf(kVal, apply(k, a.val, b.l.val)), b.r)
		}
	}
	return bin(k, a, b)
}

func eval(e *expr) int {
	switch e.kind {
	case kVar:
		return 0
	case kVal:
		return e.val
	case kAdd:
		return eval(e.l) + eval(e.r)
	}
	return eval(e.l) * eval(e.r)
}

func main() {
	n := 20
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	e := mkExpr(n, 1)
	fmt.Println(eval(e))
	fmt.Println(eval(cfold(reassoc(e))))
}
