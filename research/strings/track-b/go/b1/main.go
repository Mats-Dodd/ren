// B1/B4 Go twins: `b1 <tok|map|sort|group|logs> <datadir> <mode>`.
// mode: share (Go's substring shares the input, kept alive by the GC: the
// "always share" policy) or clone (strings.Clone on keep).
package main

import (
	"fmt"
	"os"
	"runtime"
	"slices"
	"strings"
	"time"
)

var clone bool

func keep(s string) string {
	if clone {
		return strings.Clone(s)
	}
	return s
}

type tokT struct {
	kind int
	text string
}

func isAlpha(c byte) bool { return c|32 >= 'a' && c|32 <= 'z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func tok(src string) {
	t0 := time.Now()
	n := len(src)
	var ts []tokT
	for i := 0; i < n; {
		c := src[i]
		if c == ' ' || c == '\n' || c == '\t' {
			i++
			continue
		}
		j := i + 1
		kind := 0
		if c == '_' || isAlpha(c) {
			for j < n && (src[j] == '_' || isAlpha(src[j]) || isDigit(src[j])) {
				j++
			}
		} else if isDigit(c) {
			for j < n && isDigit(src[j]) {
				j++
			}
			kind = 1
		} else if c == '"' {
			for j < n && src[j] != '"' {
				j++
			}
			j++
			kind = 2
		} else {
			if j < n && (((c == '=' || c == '!' || c == '<' || c == '>' || c == '+') && src[j] == '=') || (c == '-' && src[j] == '>')) {
				j++
			}
			kind = 3
		}
		ts = append(ts, tokT{kind, keep(src[i:j])})
		i = j
	}
	scan := time.Since(t0).Nanoseconds()
	t1 := time.Now()
	var returns, idents, total int64
	for _, t := range ts {
		if t.text == "return" {
			returns++
		}
		if t.kind == 0 {
			idents++
		}
		total += int64(len(t.text))
	}
	use := time.Since(t1).Nanoseconds()
	fmt.Printf("check=%d,%d,%d,%d\n", len(ts), returns, idents, total)
	fmt.Printf("scan_ns=%d\nuse_ns=%d\ntotal_ns=%d\n", scan, use, scan+use)
}

func lines(src string) []string { return strings.Split(strings.TrimSuffix(src, "\n"), "\n") }

func mapW(src string) {
	t0 := time.Now()
	m := map[string]int64{}
	n := len(src)
	for i := 0; i < n; {
		j := i + strings.IndexByte(src[i:], '\n')
		k := src[i:j]
		if v, ok := m[k]; ok {
			m[k] = v + 1
		} else {
			m[keep(k)] = 1
		}
		i = j + 1
	}
	build := time.Since(t0).Nanoseconds()
	t1 := time.Now()
	var sum int64
	for i := 0; i < n; {
		j := i + strings.IndexByte(src[i:], '\n')
		sum += m[src[i:j]]
		i = j + 1
	}
	lookup := time.Since(t1).Nanoseconds()
	fmt.Printf("check=%d,%d\n", len(m), sum)
	fmt.Printf("build_ns=%d\nlookup_ns=%d\ntotal_ns=%d\n", build, lookup, build+lookup)
}

func sortW(src string) {
	t0 := time.Now()
	var xs []string
	n := len(src)
	for i := 0; i < n; {
		j := i + strings.IndexByte(src[i:], '\n')
		xs = append(xs, keep(src[i:j]))
		i = j + 1
	}
	sl := time.Since(t0).Nanoseconds()
	t1 := time.Now()
	slices.Sort(xs)
	so := time.Since(t1).Nanoseconds()
	var check int64
	for k := 0; k < len(xs); k += 1000 {
		check += int64(len(xs[k]))*int64(k) + int64(xs[k][0])
	}
	fmt.Printf("check=%d,%d\n", len(xs), check)
	fmt.Printf("slice_ns=%d\nsort_ns=%d\ntotal_ns=%d\n", sl, so, sl+so)
}

func group(src string) {
	t0 := time.Now()
	m := map[string]int64{}
	n := len(src)
	for i := 0; i < n; {
		j := i + strings.IndexByte(src[i:], '\n')
		line := src[i:j]
		c1 := strings.IndexByte(line, ',')
		k := strings.LastIndexByte(line, ',')
		var amt int64
		for q := k + 1; q < len(line); q++ {
			amt = amt*10 + int64(line[q]-'0')
		}
		city := line[:c1]
		if v, ok := m[city]; ok {
			m[city] = v + amt
		} else {
			m[keep(city)] = amt
		}
		i = j + 1
	}
	var check, total int64
	for k, v := range m {
		check ^= int64(len(k))*1000003 + v
		total += v
	}
	t := time.Since(t0).Nanoseconds()
	fmt.Printf("check=%d,%d,%d\n", len(m), total, check)
	fmt.Printf("total_ns=%d\n", t)
}

type rec struct {
	ts, level, svc, method, path, req string
	status, dur                       int64
}

func logs(src string) {
	t0 := time.Now()
	var rs []rec
	n := len(src)
	var f [8]string
	for i := 0; i < n; {
		j := i + strings.IndexByte(src[i:], '\n')
		line := src[i:j]
		q := 0
		for k := 0; k < 7; k++ {
			e := q + strings.IndexByte(line[q:], ' ')
			f[k] = line[q:e]
			q = e + 1
		}
		f[7] = line[q:]
		var status, dur int64
		for _, d := range []byte(f[5]) {
			status = status*10 + int64(d-'0')
		}
		for _, d := range []byte(f[6][:len(f[6])-2]) {
			dur = dur*10 + int64(d-'0')
		}
		rs = append(rs, rec{keep(f[0]), keep(f[1]), keep(f[2]), keep(f[3]), keep(f[4]), keep(f[7][7:]), status, dur})
		i = j + 1
	}
	parse := time.Since(t0).Nanoseconds()
	t1 := time.Now()
	var errors, slow, users int64
	for k := range rs {
		r := &rs[k]
		if r.level == "ERROR" {
			errors++
		}
		if r.status >= 500 {
			slow += r.dur
		}
		if strings.HasPrefix(r.path, "/v1/users") {
			users++
		}
	}
	query := time.Since(t1).Nanoseconds()
	fmt.Printf("check=%d,%d,%d,%d\n", len(rs), errors, slow, users)
	fmt.Printf("parse_ns=%d\nquery_ns=%d\ntotal_ns=%d\n", parse, query, parse+query)
}

func main() {
	w, dir, mode := os.Args[1], os.Args[2], os.Args[3]
	clone = mode == "clone"
	file := map[string]string{"tok": "tok.txt", "map": "keys.txt", "sort": "sort.txt", "group": "rows.csv", "logs": "logs.txt"}[w]
	b, err := os.ReadFile(dir + "/" + file)
	if err != nil {
		panic(err)
	}
	src := string(b)
	b = nil
	runtime.GC()
	switch w {
	case "tok":
		tok(src)
	case "map":
		mapW(src)
	case "sort":
		sortW(src)
	case "group":
		group(src)
	case "logs":
		logs(src)
	}
	_ = lines
	fmt.Printf("repr=go-%s\n", mode)
}
