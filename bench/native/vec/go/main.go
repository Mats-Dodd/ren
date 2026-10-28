// Loops over arrays: each kernel over slices of `n` elements, `rounds`
// times. Arithmetic on int64 wraps, as Go's does; a store into a uint8
// is checked to fit, as Ren's is. The Float sum adds in eight lanes, as
// Ren's `sum` is defined to.
package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

func dot(xs, ys []float64) float64 {
	t := 0.0
	for i := range xs {
		if i >= len(ys) {
			break
		}
		t += xs[i] * ys[i]
	}
	return t
}

func fsum(xs []float64) float64 {
	var l [8]float64
	for i, x := range xs {
		l[i%8] += x
	}
	return ((l[0] + l[1]) + (l[2] + l[3])) + ((l[4] + l[5]) + (l[6] + l[7]))
}

func scale(xs []float64, k float64) {
	for i := range xs {
		xs[i] *= k
	}
}

func axpy(ys []float64, a float64, xs []float64) {
	for i := range ys {
		ys[i] += a * xs[i]
	}
}

func churn(xs []int64) {
	for i := range xs {
		xs[i] = int64(uint64(xs[i])*6364136223846793005 + 1442695040888963407)
	}
}

func total(xs []int64) int64 {
	t := int64(0)
	for _, x := range xs {
		t += x
	}
	return t
}

func blend(xs, ys []uint8) {
	for i := range xs {
		v := (int64(xs[i]) + int64(ys[i])) / 2
		if v < 0 || v > 255 {
			panic("doesn't fit")
		}
		xs[i] = uint8(v)
	}
}

func milli(x float64) int64 {
	return int64(math.Round(x * 1000.0))
}

func arg(i int, d int64) int64 {
	if len(os.Args) > i {
		v, err := strconv.ParseInt(os.Args[i], 10, 64)
		if err == nil {
			return v
		}
	}
	return d
}

func main() {
	n := arg(1, 1000)
	rounds := arg(2, 1000000)
	only := arg(3, 0)
	fs := []float64{}
	gs := []float64{}
	is := []int64{}
	bs := []uint8{}
	cs := []uint8{}
	for i := int64(0); i < n; i++ {
		fs = append(fs, float64(i%100)/64.0)
		gs = append(gs, float64(i%7)/4.0)
		is = append(is, i)
		bs = append(bs, uint8(i%256))
		cs = append(cs, uint8(i*7%256))
	}
	if only == 0 || only == 1 {
		d := 0.0
		for r := int64(0); r < rounds; r++ {
			d += dot(fs, gs)
		}
		fmt.Println(milli(d))
	}
	if only == 0 || only == 2 {
		s := 0.0
		for r := int64(0); r < rounds; r++ {
			s += fsum(fs)
		}
		fmt.Println(milli(s))
	}
	if only == 0 || only == 3 {
		g := append([]float64{}, gs...)
		for r := int64(0); r < rounds; r++ {
			k := 0.5
			if r%2 == 0 {
				k = 2.0
			}
			scale(g, k)
		}
		fmt.Println(milli(fsum(g)))
	}
	if only == 0 || only == 4 {
		ys := append([]float64{}, gs...)
		for r := int64(0); r < rounds; r++ {
			a := -0.25
			if r%2 == 0 {
				a = 0.25
			}
			axpy(ys, a, fs)
		}
		fmt.Println(milli(fsum(ys)))
	}
	if only == 0 || only == 5 {
		xs := append([]int64{}, is...)
		for r := int64(0); r < rounds; r++ {
			churn(xs)
		}
		fmt.Println(xs[n-1] % 1000003)
	}
	if only == 0 || only == 6 {
		t := int64(0)
		for r := int64(0); r < rounds; r++ {
			t = (t + total(is)) % 1000003
		}
		fmt.Println(t)
	}
	if only == 0 || only == 7 {
		xs := append([]uint8{}, bs...)
		for r := int64(0); r < rounds; r++ {
			blend(xs, cs)
		}
		s := int64(0)
		for _, x := range xs {
			s += int64(x)
		}
		fmt.Println(s)
	}
}
