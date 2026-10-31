// The Cost table's push iter.Seq and coroutine iter.Pull forms.
package main

import (
	"bytes"
	"fmt"
	"iter"
	"os"
	"strconv"
)

func random(s *int64) int64 { *s = *s * 48271 % 2147483647; return *s }
func logInput(n int) []byte {
	b := make([]byte, 0, n*73)
	s := int64(42)
	for i := 0; i < n; i++ {
		x := random(&s)
		id := random(&s) % 1000000000
		length := 20 + random(&s)%40
		if x%20 == 0 {
			b = append(b, 'E')
		} else {
			b = append(b, 'I')
		}
		b = append(b, ' ')
		for j := 0; j < 9; j++ {
			b = append(b, byte('0'+id%10))
			id /= 10
		}
		b = append(b, ' ')
		for j := int64(0); j < length; j++ {
			b = append(b, byte('a'+(x+j)%26))
		}
		b = append(b, '\n')
	}
	return b
}

type Entry struct {
	error bool
	id    int64
}

func parse(b []byte) Entry {
	id := int64(0)
	for _, c := range b[2:11] {
		id = id*10 + int64(c-'0')
	}
	return Entry{b[0] == 'E', id}
}
func lines(b []byte) iter.Seq[[]byte] {
	return func(yield func([]byte) bool) {
		for at := 0; at < len(b); {
			end := bytes.IndexByte(b[at:], '\n')
			if end < 0 {
				end = len(b)
			} else {
				end += at
			}
			if !yield(b[at:end]) {
				return
			}
			at = end + 1
		}
	}
}
func Map[A, B any](src iter.Seq[A], f func(A) B) iter.Seq[B] {
	return func(yield func(B) bool) {
		for x := range src {
			if !yield(f(x)) {
				return
			}
		}
	}
}
func Filter[A any](src iter.Seq[A], f func(A) bool) iter.Seq[A] {
	return func(yield func(A) bool) {
		for x := range src {
			if f(x) && !yield(x) {
				return
			}
		}
	}
}
func Take[A any](src iter.Seq[A], left int) iter.Seq[A] {
	return func(yield func(A) bool) {
		if left <= 0 {
			return
		}
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
func Dedup(src iter.Seq[int64]) iter.Seq[int64] {
	return func(yield func(int64) bool) {
		have := false
		last := int64(0)
		for x := range src {
			if !have || x != last {
				have = true
				last = x
				if !yield(x) {
					return
				}
			}
		}
	}
}
func total(src iter.Seq[Entry], salt int64) int64 {
	sum := int64(0)
	for e := range src {
		sum += (e.id ^ salt) + 1
	}
	return sum
}

//go:noinline
func passed(b []byte, salt int64) int64 {
	return total(Filter(Map(lines(b), parse), func(e Entry) bool { return e.error }), salt)
}

//go:noinline
func logsPush(b []byte, limit int, salt int64) int64 {
	sum := int64(0)
	for e := range Take(Filter(Map(lines(b), parse), func(e Entry) bool { return e.error }), limit) {
		sum += (e.id ^ salt) + 1
	}
	return sum
}

//go:noinline
func logsPull(b []byte, limit int, salt int64) int64 {
	next, stop := iter.Pull(Take(Filter(Map(lines(b), parse), func(e Entry) bool { return e.error }), limit))
	defer stop()
	sum := int64(0)
	for {
		e, ok := next()
		if !ok {
			break
		}
		sum += (e.id ^ salt) + 1
	}
	return sum
}

type Tree struct {
	value int64
	kids  []*Tree
}

func treeInput(lo, hi int) *Tree {
	if lo >= hi {
		return nil
	}
	mid := (lo + hi) / 2
	t := &Tree{value: (int64(mid)*48271 + 7) % 2147483647}
	if a := treeInput(lo, mid); a != nil {
		t.kids = append(t.kids, a)
	}
	if b := treeInput(mid+1, hi); b != nil {
		t.kids = append(t.kids, b)
	}
	return t
}
func walk(t *Tree, yield func(int64) bool) bool {
	if t == nil {
		return true
	}
	if !yield(t.value) {
		return false
	}
	for _, c := range t.kids {
		if !walk(c, yield) {
			return false
		}
	}
	return true
}
func all(t *Tree) iter.Seq[int64] { return func(yield func(int64) bool) { walk(t, yield) } }
func deltasInput(n int) []int64 {
	xs := make([]int64, n)
	s := int64(99)
	for i := range xs {
		if random(&s)%16 == 0 {
			xs[i] = 1
		}
	}
	return xs
}
func ticks(xs []int64, salt int64) iter.Seq[int64] {
	return func(yield func(int64) bool) {
		v := salt
		for _, d := range xs {
			v += d
			if !yield(v) {
				return
			}
		}
	}
}
func zipInput(n int) []int64 {
	xs := make([]int64, n)
	s := int64(5)
	for i := range xs {
		x := random(&s)
		if x%8 == 0 {
			xs[i] = -1 - x/8
		} else {
			xs[i] = x / 8
		}
	}
	return xs
}
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

//go:noinline
func zip(xs []int64, na, salt int64, pullBoth bool) int64 {
	next, stop := iter.Pull(nonneg(xs))
	defer stop()
	sum := int64(0)
	if pullBoth {
		a, stopA := iter.Pull(thirds(na))
		defer stopA()
		for {
			x, ok := a()
			if !ok {
				break
			}
			y, ok := next()
			if !ok {
				break
			}
			sum += x ^ y ^ salt
		}
	} else {
		for a := range thirds(na) {
			b, ok := next()
			if !ok {
				break
			}
			sum += a ^ b ^ salt
		}
	}
	return sum
}

//go:noinline
func treePush(t *Tree, limit int, salt int64) int64 {
	sum := int64(0)
	for x := range Take(Filter(all(t), func(x int64) bool { return x%7 == 0 }), limit) {
		sum += x ^ salt
	}
	return sum
}

//go:noinline
func treePull(t *Tree, limit int, salt int64) int64 {
	next, stop := iter.Pull(Take(Filter(all(t), func(x int64) bool { return x%7 == 0 }), limit))
	defer stop()
	sum := int64(0)
	for {
		x, ok := next()
		if !ok {
			break
		}
		sum += x ^ salt
	}
	return sum
}

//go:noinline
func dedupPush(ds []int64, salt int64) int64 {
	sum := int64(0)
	for x := range Dedup(Map(ticks(ds, salt), func(x int64) int64 { return x / 2 })) {
		sum += x
	}
	return sum
}

//go:noinline
func dedupPull(ds []int64, salt int64) int64 {
	next, stop := iter.Pull(Dedup(Map(ticks(ds, salt), func(x int64) int64 { return x / 2 })))
	defer stop()
	sum := int64(0)
	for {
		x, ok := next()
		if !ok {
			break
		}
		sum += x
	}
	return sum
}
func main() {
	n, rounds := 1000000, 20
	variant, which := "push", "all"
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	if len(os.Args) > 2 {
		rounds, _ = strconv.Atoi(os.Args[2])
	}
	if len(os.Args) > 3 {
		variant = os.Args[3]
	}
	if len(os.Args) > 4 {
		which = os.Args[4]
	}
	if n < 25 || rounds < 1 {
		panic("size must be >=25 and rounds positive")
	}
	pull := variant == "pull" || variant == "pull2"
	for _, w := range []string{"w1", "w2", "w3", "w4", "w5"} {
		if which != "all" && which != w {
			continue
		}
		var b []byte
		var t *Tree
		var ds, xs []int64
		if w == "w1" || w == "w5" {
			b = logInput(n)
		}
		if w == "w2" {
			t = treeInput(0, n)
		}
		if w == "w3" {
			ds = deltasInput(n)
		}
		if w == "w4" {
			xs = zipInput(n)
		}
		sum := int64(0)
		for r := 0; r < rounds; r++ {
			salt := int64(r)
			switch w {
			case "w1":
				if pull {
					sum += logsPull(b, n/25, salt)
				} else {
					sum += logsPush(b, n/25, salt)
				}
			case "w5":
				sum += passed(b, salt)
			case "w2":
				if pull {
					sum += treePull(t, n/8, salt)
				} else {
					sum += treePush(t, n/8, salt)
				}
			case "w3":
				if pull {
					sum += dedupPull(ds, salt)
				} else {
					sum += dedupPush(ds, salt)
				}
			case "w4":
				sum += zip(xs, int64(n)*21/16, salt, variant == "pull2")
			}
		}
		fmt.Println(sum)
	}
}
