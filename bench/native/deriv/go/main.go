// Symbolic differentiation: Koka's deriv benchmark
// (test/bench/koka/deriv.kk). Terms share their parts.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type kind int

const (
	kVal kind = iota
	kVar
	kAdd
	kMul
	kPow
	kLn
)

type expr struct {
	kind kind
	val  int
	name string
	l, r *expr // Ln keeps its operand in l
}

func val(n int) *expr              { return &expr{kind: kVal, val: n} }
func bin(k kind, l, r *expr) *expr { return &expr{kind: k, l: l, r: r} }

func isVal(e *expr, n int) bool { return e.kind == kVal && e.val == n }

// a to the power b, by squaring; a negative b counts as 0 or 1
func pown(a, b int) int {
	if b == 0 {
		return 1
	} else if b == 1 {
		return a
	}
	y := pown(a, b/2)
	if b%2 == 0 {
		return y * y
	}
	return y * y * a
}

func add(x, y *expr) *expr {
	switch {
	case x.kind == kVal && y.kind == kVal:
		return val(x.val + y.val)
	case isVal(x, 0):
		return y
	case isVal(y, 0):
		return x
	case y.kind == kVal:
		return add(y, x)
	case x.kind == kVal && y.kind == kAdd && y.l.kind == kVal:
		return add(val(x.val+y.l.val), y.r)
	case y.kind == kAdd && y.l.kind == kVal:
		return add(y.l, add(x, y.r))
	case x.kind == kAdd:
		return add(x.l, add(x.r, y))
	}
	return bin(kAdd, x, y)
}

func mul(x, y *expr) *expr {
	switch {
	case x.kind == kVal && y.kind == kVal:
		return val(x.val * y.val)
	case isVal(x, 0), isVal(y, 0):
		return val(0)
	case isVal(x, 1):
		return y
	case isVal(y, 1):
		return x
	case y.kind == kVal:
		return mul(y, x)
	case x.kind == kVal && y.kind == kMul && y.l.kind == kVal:
		return mul(val(x.val*y.l.val), y.r)
	case y.kind == kMul && y.l.kind == kVal:
		return mul(y.l, mul(x, y.r))
	case x.kind == kMul:
		return mul(x.l, mul(x.r, y))
	}
	return bin(kMul, x, y)
}

func powr(x, y *expr) *expr {
	switch {
	case x.kind == kVal && y.kind == kVal:
		return val(pown(x.val, y.val))
	case isVal(y, 0):
		return val(1)
	case isVal(y, 1):
		return x
	case isVal(x, 0):
		return val(0)
	}
	return bin(kPow, x, y)
}

func ln(n *expr) *expr {
	if isVal(n, 1) {
		return val(0)
	}
	return &expr{kind: kLn, l: n}
}

func d(x string, e *expr) *expr {
	switch e.kind {
	case kVal:
		return val(0)
	case kVar:
		if e.name == x {
			return val(1)
		}
		return val(0)
	case kAdd:
		return add(d(x, e.l), d(x, e.r))
	case kMul:
		f, g := e.l, e.r
		return add(mul(f, d(x, g)), mul(g, d(x, f)))
	case kPow:
		f, g := e.l, e.r
		return mul(powr(f, g), add(mul(mul(g, d(x, f)), powr(f, val(-1))), mul(ln(f), d(x, g))))
	}
	f := e.l
	return mul(d(x, f), powr(f, val(-1)))
}

func count(e *expr) int {
	switch e.kind {
	case kVal, kVar:
		return 1
	case kLn:
		return count(e.l)
	}
	return count(e.l) + count(e.r)
}

func main() {
	n := 10
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	x := &expr{kind: kVar, name: "x"}
	e := powr(x, x)
	for i := 0; i < n; i++ {
		e = d("x", e)
		fmt.Printf("%d count: %d\n", i+1, count(e))
	}
	fmt.Println("done")
}
