// Sized storage: a million bytes in a []uint8 and a million int32s,
// each changed in place a round at a time, and an FNV-1a hash of the
// bytes at 32 bits. Arithmetic is in int64, as Ren's is, and each store
// is checked to fit, as Ren's are.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func next(s int64) int64 {
	return int64(uint64(s)*6364136223846793005 + 1442695040888963407)
}

func fit(x, lo, hi int64) int64 {
	if x < lo || x > hi {
		panic("doesn't fit")
	}
	return x
}

func bytes(n int64) []uint8 {
	xs := []uint8{}
	s := int64(42)
	for i := int64(0); i < n; i++ {
		s = next(s)
		xs = append(xs, uint8(fit((s/4294967296)&255, 0, 255)))
	}
	return xs
}

func ints(n int64) []int32 {
	xs := []int32{}
	s := int64(7)
	for i := int64(0); i < n; i++ {
		s = next(s)
		xs = append(xs, int32(fit((s/4294967296)%1000003, -2147483648, 2147483647)))
	}
	return xs
}

func smooth(xs []uint8, rounds int64) {
	for r := int64(0); r < rounds; r++ {
		for i := 1; i < len(xs); i++ {
			xs[i] = uint8(fit((int64(xs[i])+int64(xs[i-1]))/2, 0, 255))
		}
	}
}

func mix(xs []int32, rounds int64) {
	for r := int64(0); r < rounds; r++ {
		for i := 1; i < len(xs); i++ {
			xs[i] = int32(fit((int64(xs[i])*3+int64(xs[i-1]))%1000003, -2147483648, 2147483647))
		}
	}
}

func fnv(xs []uint8, seed int64) int64 {
	h := uint32(fit(2166136261+seed, 0, 4294967295))
	for _, b := range xs {
		h ^= uint32(b)
		h *= 16777619
	}
	return int64(h)
}

func main() {
	n, rounds := int64(1_000_000), int64(100)
	if len(os.Args) > 1 {
		n, _ = strconv.ParseInt(os.Args[1], 10, 64)
	}
	if len(os.Args) > 2 {
		rounds, _ = strconv.ParseInt(os.Args[2], 10, 64)
	}
	bs := bytes(n)
	is := ints(n)
	smooth(bs, rounds)
	mix(is, rounds)
	var a, b int64
	for _, x := range bs {
		a += int64(x)
	}
	for _, x := range is {
		b += int64(x)
	}
	fmt.Println(a)
	fmt.Println(b)
	h := int64(0)
	for r := int64(0); r < rounds; r++ {
		h = (h + fnv(bs, r)) % 4294967296
	}
	fmt.Println(h)
}
