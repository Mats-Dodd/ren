// E3's Go twins: range over func (iter.Seq) for push, iter.Pull for
// pull, one goroutine. The adapters (Map, Filter, Take, DedupBy) are
// written by hand, since the standard library has none for iter.Seq;
// that's how Go code using iterators writes them.
package main

import (
	"bytes"
	"fmt"
	"iter"
	"os"
	"strconv"
	"time"
)

type Rng struct{ s uint64 }

func (r *Rng) Next() uint64 {
	r.s = r.s*6364136223846793005 + 1442695040888963407
	return r.s >> 33
}

// ---------------- adapters ----------------
func Map[T, U any](src iter.Seq[T], f func(T) U) iter.Seq[U] {
	return func(yield func(U) bool) {
		for x := range src {
			if !yield(f(x)) {
				return
			}
		}
	}
}

func Filter[T any](src iter.Seq[T], p func(T) bool) iter.Seq[T] {
	return func(yield func(T) bool) {
		for x := range src {
			if p(x) && !yield(x) {
				return
			}
		}
	}
}

func Take[T any](src iter.Seq[T], n int) iter.Seq[T] {
	return func(yield func(T) bool) {
		if n <= 0 {
			return
		}
		left := n
		for x := range src {
			if !yield(x) {
				return
			}
			left--
			if left == 0 {
				return
			}
		}
	}
}

func DedupBy[T any, K comparable](src iter.Seq[T], key func(T) K) iter.Seq[T] {
	return func(yield func(T) bool) {
		have := false
		var last K
		for x := range src {
			k := key(x)
			if !have || k != last {
				have, last = true, k
				if !yield(x) {
					return
				}
			}
		}
	}
}

// ---------------- W1 and W5 ----------------
func makeLog(target int) []byte {
	b := make([]byte, 0, target+256)
	r := Rng{42}
	lv := []string{"DEBUG", "INFO", "WARN", "ERROR"}
	sv := []string{"api", "db", "auth", "cache"}
	for len(b) < target {
		x := r.Next()
		sec, ms, p := x%60, (x>>8)%1000, (x>>20)%100
		var l string
		switch {
		case p < 30:
			l = lv[0]
		case p < 80:
			l = lv[1]
		case p < 95:
			l = lv[2]
		default:
			l = lv[3]
		}
		s := sv[(x>>27)%4]
		id := r.Next() % 1000000000
		mlen := 20 + r.Next()%60
		b = append(b, "2026-10-29T11:43:"...)
		b = append(b, byte('0'+sec/10), byte('0'+sec%10), '.',
			byte('0'+ms/100), byte('0'+ms/10%10), byte('0'+ms%10), 'Z', ' ')
		b = append(b, l...)
		b = append(b, " svc="...)
		b = append(b, s...)
		b = append(b, " id="...)
		b = strconv.AppendUint(b, id, 10)
		b = append(b, " msg="...)
		for i := uint64(0); i < mlen; i++ {
			b = append(b, byte('a'+r.Next()%26))
		}
		b = append(b, '\n')
	}
	return b
}

const (
	DEBUG = 0
	INFO  = 1
	WARN  = 2
	ERROR = 3
	BAD   = -1
)

type Entry struct{ level, id int64 }

func parse(p []byte) Entry {
	n, i := len(p), 25
	e := Entry{BAD, 0}
	if n <= i {
		return e
	}
	switch p[i] {
	case 'D':
		e.level = DEBUG
	case 'I':
		e.level = INFO
	case 'W':
		e.level = WARN
	case 'E':
		e.level = ERROR
	default:
		return e
	}
	for i < n && p[i] != ' ' {
		i++
	}
	i++
	for i < n && p[i] != ' ' {
		i++
	}
	i += 4
	var id int64
	for i < n && p[i] >= '0' && p[i] <= '9' {
		id = id*10 + int64(p[i]-'0')
		i++
	}
	e.id = id
	return e
}

func lines(b []byte) iter.Seq[[]byte] {
	return func(yield func([]byte) bool) {
		i := 0
		for i < len(b) {
			j := bytes.IndexByte(b[i:], '\n')
			if j < 0 {
				j = len(b)
			} else {
				j += i
			}
			if !yield(b[i:j]) {
				return
			}
			i = j + 1
		}
	}
}

func isErr(e Entry) bool { return e.level == ERROR }

const w1Take = 40000

// the obvious Go: a range over the adapted iterator
//
//go:noinline
func w1Push(b []byte) (int64, int64) {
	var n, ids int64
	for e := range Take(Filter(Map(lines(b), parse), isErr), w1Take) {
		n++
		ids += e.id
	}
	return n, ids
}

// the obvious Go with the stages in the body
//
//go:noinline
func w1Loop(b []byte) (int64, int64) {
	var n, ids int64
	for l := range lines(b) {
		e := parse(l)
		if e.level != ERROR {
			continue
		}
		n++
		ids += e.id
		if n == w1Take {
			break
		}
	}
	return n, ids
}

//go:noinline
func w1Pull(b []byte) (int64, int64) {
	var n, ids int64
	next, stop := iter.Pull(Take(Filter(Map(lines(b), parse), isErr), w1Take))
	defer stop()
	for {
		e, ok := next()
		if !ok {
			break
		}
		n++
		ids += e.id
	}
	return n, ids
}

func total(rows iter.Seq[Entry]) (int64, int64) {
	var n, ids int64
	for e := range rows {
		n++
		ids += e.id
	}
	return n, ids
}

//go:noinline
func w5Inline(b []byte) (int64, int64) {
	var n, ids int64
	for e := range Filter(Map(lines(b), parse), isErr) {
		n++
		ids += e.id
	}
	return n, ids
}

//go:noinline
func w5Passed(b []byte) (int64, int64) {
	return total(Filter(Map(lines(b), parse), isErr))
}

// ---------------- W2 ----------------
type Tree struct {
	val  int64
	kids []*Tree
}

func build(r *Rng, d int) *Tree {
	t := &Tree{val: int64(r.Next())}
	n := 0
	if d < 20 {
		if d%5 == 2 {
			n = 3
		} else {
			n = 2
		}
	}
	t.kids = make([]*Tree, n)
	for i := range t.kids {
		t.kids[i] = build(r, d+1)
	}
	return t
}

func (t *Tree) walk(yield func(int64) bool) bool {
	if !yield(t.val) {
		return false
	}
	for _, c := range t.kids {
		if !c.walk(yield) {
			return false
		}
	}
	return true
}

func (t *Tree) All() iter.Seq[int64] {
	return func(yield func(int64) bool) { t.walk(yield) }
}

const w2Take = 1300000

func sevens(v int64) bool { return v%7 == 0 }

//go:noinline
func w2Push(t *Tree) int64 {
	var sum int64
	for v := range Take(Filter(t.All(), sevens), w2Take) {
		sum += v
	}
	return sum
}

//go:noinline
func w2Pull(t *Tree) int64 {
	var sum int64
	next, stop := iter.Pull(Take(Filter(t.All(), sevens), w2Take))
	defer stop()
	for {
		v, ok := next()
		if !ok {
			break
		}
		sum += v
	}
	return sum
}

// ---------------- W3 ----------------
func ticks(ds []int64) iter.Seq[int64] {
	return func(yield func(int64) bool) {
		var v int64
		for _, d := range ds {
			v += d
			if !yield(v) {
				return
			}
		}
	}
}

func half(x int64) int64 { return x / 2 }
func ident(x int64) int64 { return x }

//go:noinline
func w3Push(ds []int64) int64 {
	var sum int64
	for x := range DedupBy(Map(ticks(ds), half), ident) {
		sum += x
	}
	return sum
}

//go:noinline
func w3Pull(ds []int64) int64 {
	var sum int64
	next, stop := iter.Pull(DedupBy(Map(ticks(ds), half), ident))
	defer stop()
	for {
		x, ok := next()
		if !ok {
			break
		}
		sum += x
	}
	return sum
}

// ---------------- W4 ----------------
const nb = 16 << 20
const na = 22020096

func thirds(n int64) iter.Seq[int64] {
	return func(yield func(int64) bool) {
		for i := int64(0); i < n; i++ {
			if i%3 != 0 && !yield(i) {
				return
			}
		}
	}
}

func nonneg(xs []int64) iter.Seq[int64] {
	return func(yield func(int64) bool) {
		for _, x := range xs {
			if x >= 0 && !yield(x) {
				return
			}
		}
	}
}

// range over one, pull the other
//
//go:noinline
func w4Pull1(bs []int64) int64 {
	var sum int64
	next, stop := iter.Pull(nonneg(bs))
	defer stop()
	for a := range thirds(na) {
		b, ok := next()
		if !ok {
			break
		}
		sum += a ^ b
	}
	return sum
}

// pull both
//
//go:noinline
func w4Pull2(bs []int64) int64 {
	var sum int64
	na_, sa := iter.Pull(thirds(na))
	defer sa()
	nb_, sb := iter.Pull(nonneg(bs))
	defer sb()
	for {
		a, ok := na_()
		if !ok {
			break
		}
		b, ok := nb_()
		if !ok {
			break
		}
		sum += a ^ b
	}
	return sum
}

func main() {
	w, v := os.Args[1], os.Args[2]
	switch w {
	case "w1", "w5":
		b := makeLog(100 << 20)
		var n, ids int64
		t0 := time.Now()
		for r := 0; r < 5; r++ {
			var x, y int64
			switch w + "/" + v {
			case "w1/push":
				x, y = w1Push(b)
			case "w1/loop":
				x, y = w1Loop(b)
			case "w1/pull":
				x, y = w1Pull(b)
			case "w5/inline":
				x, y = w5Inline(b)
			case "w5/passed":
				x, y = w5Passed(b)
			default:
				panic("variant?")
			}
			n += x
			ids += y
		}
		el := time.Since(t0).Nanoseconds()
		fmt.Printf("bytes=%d\ncheck=%d:%d\n%s_ns=%d\n", len(b), n, ids, w, el)
	case "w2":
		r := Rng{7}
		t := build(&r, 0)
		var s int64
		t0 := time.Now()
		for k := 0; k < 3; k++ {
			switch v {
			case "push":
				s += w2Push(t)
			case "pull":
				s += w2Pull(t)
			default:
				panic("variant?")
			}
		}
		el := time.Since(t0).Nanoseconds()
		fmt.Printf("check=%d\nw2_ns=%d\n", s, el)
	case "w3":
		r := Rng{99}
		ds := make([]int64, 16<<20)
		for i := range ds {
			if r.Next()%16 == 0 {
				ds[i] = 1
			}
		}
		var s int64
		t0 := time.Now()
		for k := 0; k < 8; k++ {
			switch v {
			case "push":
				s += w3Push(ds)
			case "pull":
				s += w3Pull(ds)
			default:
				panic("variant?")
			}
		}
		el := time.Since(t0).Nanoseconds()
		fmt.Printf("check=%d\nw3_ns=%d\n", s, el)
	case "w4":
		r := Rng{5}
		bs := make([]int64, nb)
		for i := range bs {
			x := r.Next()
			if x%8 == 0 {
				bs[i] = -1 - int64(x>>3)
			} else {
				bs[i] = int64(x >> 3)
			}
		}
		var s int64
		t0 := time.Now()
		for k := 0; k < 8; k++ {
			switch v {
			case "pull1":
				s += w4Pull1(bs)
			case "pull2":
				s += w4Pull2(bs)
			default:
				panic("variant?")
			}
		}
		el := time.Since(t0).Nanoseconds()
		fmt.Printf("check=%d\nw4_ns=%d\n", s, el)
	}
}
