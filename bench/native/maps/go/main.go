// `Map` natively: accounts kept in a map keyed by int64 id and one keyed
// by name, each round built, looked up, a third removed and iterated in
// insertion order, into a checksum. Each map is Go's map (seeded, as
// Ren's is) of a key to its entry's place in a slice of entries, in
// insertion order, a removed one left a hole until a third are holes,
// then compacted: indexmap's shape, which Ren's map has (ren_rt.h,
// [ren_map]). Arithmetic is int64, wrapping as Ren's wrapping_ does.
package main

import (
	"fmt"
	"os"
	"strconv"
)

type entry[K comparable, V any] struct {
	k    K
	v    V
	live bool
}

type Ordered[K comparable, V any] struct {
	index   map[K]int
	entries []entry[K, V]
	len     int
}

func newOrdered[K comparable, V any]() *Ordered[K, V] {
	return &Ordered[K, V]{index: map[K]int{}}
}

// a key that's there keeps its place and gets the value
func (m *Ordered[K, V]) set(k K, v V) {
	if i, ok := m.index[k]; ok {
		m.entries[i].v = v
		return
	}
	m.index[k] = len(m.entries)
	m.entries = append(m.entries, entry[K, V]{k, v, true})
	m.len++
}

func (m *Ordered[K, V]) get(k K) (V, bool) {
	if i, ok := m.index[k]; ok {
		return m.entries[i].v, true
	}
	var zero V
	return zero, false
}

func (m *Ordered[K, V]) remove(k K) {
	i, ok := m.index[k]
	if !ok {
		return
	}
	delete(m.index, k)
	var zero entry[K, V]
	m.entries[i] = zero
	m.len--
	if (len(m.entries)-m.len)*3 >= len(m.entries) && len(m.entries) >= 8 {
		kept := m.entries[:0]
		for _, e := range m.entries {
			if e.live {
				m.index[e.k] = len(kept)
				kept = append(kept, e)
			}
		}
		m.entries = kept
	}
}

type Account struct {
	id      int64
	name    string
	balance int64
}

func idOf(i, n int64) int64 { return i * 2_654_435_761 % (2 * n) }

func names(n int64) []string {
	out := make([]string, n)
	for i := int64(0); i < n; i++ {
		out[i] = "user-" + strconv.FormatInt(i*7_919%n, 10)
	}
	return out
}

func round(names []string, n int64) int64 {
	byID := newOrdered[int64, Account]()
	byName := newOrdered[string, int64]()
	for i := int64(0); i < n; i++ {
		id := idOf(i, n)
		byID.set(id, Account{id, names[i], i % 1000})
		byName.set(names[i], id)
	}
	var h int64
	for i := int64(0); i < n; i++ {
		if a, ok := byID.get(i * 3); ok {
			h += a.balance
		} else {
			h++
		}
		if id, ok := byName.get(names[i*31%n]); ok {
			h += id
		} else {
			h--
		}
	}
	for i := int64(0); i < n; i++ {
		if i%3 == 0 {
			byID.remove(idOf(i, n))
			byName.remove(names[i])
		}
	}
	for _, e := range byID.entries {
		if e.live {
			h = h*31 + e.k + e.v.balance + int64(len(e.v.name))
		}
	}
	for _, e := range byName.entries {
		if e.live {
			h = h*17 + e.v + int64(len(e.k))
		}
	}
	return h + int64(byID.len)*1_000 + int64(byName.len)
}

func main() {
	n, rounds := int64(200_000), int64(20)
	if len(os.Args) > 1 {
		n, _ = strconv.ParseInt(os.Args[1], 10, 64)
	}
	if len(os.Args) > 2 {
		rounds, _ = strconv.ParseInt(os.Args[2], 10, 64)
	}
	ns := names(n)
	var x int64
	for r := int64(0); r < rounds; r++ {
		x += round(ns, n)
	}
	fmt.Println(len(ns))
	fmt.Println(x)
}
