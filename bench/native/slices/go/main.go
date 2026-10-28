// The slices benchmark's Go twin (research/slices.md): each parser with
// []byte slices of the input, and with offsets into it. `main [n]
// [rounds] [kernel]`, as the Rust twin.
package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
)

// ---- the inputs, byte for byte gen.ren's ----

func next(seed *int64) int64 {
	*seed = (*seed*1103515245 + 12345) % 2147483648
	return *seed
}

func pushInt(out []byte, n int64) []byte {
	if n >= 10 {
		out = pushInt(out, n/10)
	}
	return append(out, byte('0'+n%10))
}

func logsInput(lines int64) []byte {
	seed := int64(42)
	var out []byte
	levels := []string{"ERROR", "WARN", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO"}
	services := []string{"auth", "billing", "search", "cart"}
	resources := []string{"users", "orders", "items", "carts", "sessions"}
	for i := int64(0); i < lines; i++ {
		out = pushInt(out, 1700000000+i)
		out = append(out, ' ')
		out = append(out, levels[next(&seed)%10]...)
		out = append(out, ' ')
		out = append(out, services[next(&seed)%4]...)
		out = append(out, ' ')
		out = pushInt(out, next(&seed)%5000)
		out = append(out, ' ')
		out = append(out, "/api/v"...)
		out = pushInt(out, next(&seed)%3)
		out = append(out, '/')
		out = append(out, resources[next(&seed)%5]...)
		out = append(out, '/')
		out = pushInt(out, next(&seed)%100000)
		out = append(out, '\n')
	}
	return out
}

func key(out []byte, k string) []byte {
	out = append(out, '"')
	out = append(out, k...)
	return append(out, "\":"...)
}

func jsonInput(n int64) []byte {
	seed := int64(7)
	var out []byte
	tags := []string{"red", "green", "blue", "admin", "beta", "x"}
	out = append(out, '[')
	for i := int64(0); i < n; i++ {
		if i > 0 {
			out = append(out, ",\n"...)
		}
		out = append(out, '{')
		out = key(out, "id")
		out = pushInt(out, i)
		out = append(out, ',')
		out = key(out, "name")
		out = append(out, "\"user_"...)
		out = pushInt(out, next(&seed)%100000)
		out = append(out, '"', ',')
		out = key(out, "email")
		out = append(out, "\"u"...)
		out = pushInt(out, next(&seed)%100000)
		out = append(out, "@example.com\","...)
		out = key(out, "tags")
		out = append(out, '[')
		k := next(&seed) % 4
		for t := int64(0); t < k; t++ {
			if t > 0 {
				out = append(out, ',')
			}
			out = append(out, '"')
			out = append(out, tags[next(&seed)%6]...)
			out = append(out, '"')
		}
		out = append(out, ']', ',')
		out = key(out, "score")
		out = pushInt(out, next(&seed)%10000)
		out = append(out, ',')
		out = key(out, "active")
		if next(&seed)%2 == 0 {
			out = append(out, "true"...)
		} else {
			out = append(out, "false"...)
		}
		out = append(out, '}')
	}
	return append(out, ']')
}

func digits(n int64) int64 {
	if n < 10 {
		return 1
	}
	return 1 + digits(n/10)
}

func pagesInput(count int64) []byte {
	seed := int64(3)
	var out []byte
	id := int64(0)
	for p := int64(0); p < count; p++ {
		var keys, lens []int64
		used := int64(2)
		for {
			k := next(&seed) % 1000000
			v := 8 + next(&seed)%120
			size := 2 + 1 + 1 + digits(k) + 2 + v
			if used+size > 4096 {
				break
			}
			keys = append(keys, k)
			lens = append(lens, v)
			used += size
		}
		n := int64(len(keys))
		out = append(out, byte(n%256), byte(n/256))
		off := 2 + 2*n
		for r := range keys {
			out = append(out, byte(off%256), byte(off/256))
			off += 1 + 1 + digits(keys[r]) + 2 + lens[r]
		}
		for r := range keys {
			out = append(out, byte(1+digits(keys[r])), 'k')
			out = pushInt(out, keys[r])
			out = append(out, byte(lens[r]%256), byte(lens[r]/256))
			for i := int64(0); i < lens[r]; i++ {
				out = append(out, byte(97+(id+i)%26))
			}
			id++
		}
		for i := off; i < 4096; i++ {
			out = append(out, 0)
		}
	}
	return out
}

// ---- (a) log lines, split into fields ----

type stats struct{ errors, warns, errorLatency, pathBytes, search int64 }

func (st *stats) total() int64 {
	return st.errors + st.warns*3 + st.errorLatency + st.pathBytes*7 + st.search*11
}

func parseInt(b []byte) int64 {
	n := int64(0)
	for _, c := range b {
		n = n*10 + int64(c) - 48
	}
	return n
}

var (
	errorB  = []byte("ERROR")
	warnB   = []byte("WARN")
	searchB = []byte("search")
	scoreB  = []byte("score")
	nameB   = []byte("name")
	tagsB   = []byte("tags")
	activeB = []byte("active")
)

func line(l []byte, st *stats) {
	start, f, isError := 0, 0, false
	for k := 0; k <= len(l); k++ {
		if k == len(l) || l[k] == ' ' {
			field := l[start:k]
			switch f {
			case 1:
				if bytes.Equal(field, errorB) {
					st.errors++
					isError = true
				} else if bytes.Equal(field, warnB) {
					st.warns++
				}
			case 2:
				if bytes.Equal(field, searchB) {
					st.search++
				}
			case 3:
				if isError {
					st.errorLatency += parseInt(field)
				}
			case 4:
				st.pathBytes += int64(len(field))
			}
			f++
			start = k + 1
		}
	}
}

func logs(buf []byte) int64 {
	var st stats
	i := 0
	for j := 0; j < len(buf); j++ {
		if buf[j] == '\n' {
			line(buf[i:j], &st)
			i = j + 1
		}
	}
	return st.total()
}

func equal(b []byte, from, to int, s []byte) bool {
	if to-from != len(s) {
		return false
	}
	for i := range s {
		if b[from+i] != s[i] {
			return false
		}
	}
	return true
}

func lineR(b []byte, from, to int, st *stats) {
	start, f, isError := from, 0, false
	for k := from; k <= to; k++ {
		if k == to || b[k] == ' ' {
			switch f {
			case 1:
				if equal(b, start, k, errorB) {
					st.errors++
					isError = true
				} else if equal(b, start, k, warnB) {
					st.warns++
				}
			case 2:
				if equal(b, start, k, searchB) {
					st.search++
				}
			case 3:
				if isError {
					n := int64(0)
					for i := start; i < k; i++ {
						n = n*10 + int64(b[i]) - 48
					}
					st.errorLatency += n
				}
			case 4:
				st.pathBytes += int64(k - start)
			}
			f++
			start = k + 1
		}
	}
}

func logsR(buf []byte) int64 {
	var st stats
	i := 0
	for j := 0; j < len(buf); j++ {
		if buf[j] == '\n' {
			lineR(buf, i, j, &st)
			i = j + 1
		}
	}
	return st.total()
}

// ---- (b) a JSON-ish tokenizer, its tokens kept, then walked ----

func punct(c byte) int {
	switch c {
	case '{':
		return 1
	case '}':
		return 2
	case '[':
		return 3
	case ']':
		return 4
	case ':':
		return 5
	case ',':
		return 6
	}
	return 0
}

func space(c byte) bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

func scan(b []byte, emit func(kind, i, j int)) {
	n, i := len(b), 0
	for i < n {
		c := b[i]
		if p := punct(c); p > 0 {
			emit(p, i, i+1)
			i++
		} else if c == '"' {
			j := i + 1
			for b[j] != '"' {
				j++
			}
			emit(7, i+1, j)
			i = j + 1
		} else if c == 't' {
			emit(9, i, i+4)
			i += 4
		} else if c == 'f' {
			emit(10, i, i+5)
			i += 5
		} else if space(c) {
			i++
		} else {
			j := i
			for j < n && b[j] >= '0' && b[j] <= '9' {
				j++
			}
			emit(8, i, j)
			i = j
		}
	}
}

type tok struct {
	kind int
	text []byte
}

func json(b []byte) int64 {
	var toks []tok
	scan(b, func(k, i, j int) { toks = append(toks, tok{k, b[i:j]}) })
	var score, names, tagBytes, trues int64
	inTags := false
	for i := 0; i < len(toks)-2; i++ {
		t := &toks[i]
		if t.kind == 7 && toks[i+1].kind == 5 {
			v := &toks[i+2]
			if bytes.Equal(t.text, scoreB) {
				score += parseInt(v.text)
			} else if bytes.Equal(t.text, nameB) {
				names++
			} else if bytes.Equal(t.text, tagsB) {
				inTags = true
			} else if bytes.Equal(t.text, activeB) && v.kind == 9 {
				trues++
			}
		} else if inTags && t.kind == 7 {
			tagBytes += int64(len(t.text))
		} else if t.kind == 4 {
			inTags = false
		}
	}
	return score + names*3 + tagBytes*7 + trues*11 + int64(len(toks))*13
}

type tokR struct {
	kind        uint8
	start, stop uint32
}

func jsonR(b []byte) int64 {
	var toks []tokR
	scan(b, func(k, i, j int) { toks = append(toks, tokR{uint8(k), uint32(i), uint32(j)}) })
	s := func(t *tokR) []byte { return b[t.start:t.stop] }
	var score, names, tagBytes, trues int64
	inTags := false
	for i := 0; i < len(toks)-2; i++ {
		t := &toks[i]
		if t.kind == 7 && toks[i+1].kind == 5 {
			v := &toks[i+2]
			if bytes.Equal(s(t), scoreB) {
				score += parseInt(s(v))
			} else if bytes.Equal(s(t), nameB) {
				names++
			} else if bytes.Equal(s(t), tagsB) {
				inTags = true
			} else if bytes.Equal(s(t), activeB) && v.kind == 9 {
				trues++
			}
		} else if inTags && t.kind == 7 {
			tagBytes += int64(t.stop - t.start)
		} else if t.kind == 4 {
			inTags = false
		}
	}
	return score + names*3 + tagBytes*7 + trues*11 + int64(len(toks))*13
}

// ---- (c) pages parsed into records, kept, then queried ----

func u16(b []byte, i int) int { return int(b[i]) + 256*int(b[i+1]) }

type rec struct{ key, value []byte }

func pages(b []byte) int64 {
	var recs []rec
	for p := 0; p < len(b)/4096; p++ {
		base := p * 4096
		for r := 0; r < u16(b, base); r++ {
			at := base + u16(b, base+2+2*r)
			klen := int(b[at])
			vat := at + 1 + klen
			vlen := u16(b, vat)
			recs = append(recs, rec{b[at+1 : vat], b[vat+2 : vat+2+vlen]})
		}
	}
	var k1, sevens, vowels int64
	for _, r := range recs {
		if r.key[1] == '1' {
			k1++
		}
		if r.key[len(r.key)-1] == '7' {
			sevens += int64(len(r.value))
		}
		if r.value[0] == 'a' {
			vowels++
		}
	}
	return k1 + sevens*3 + vowels*7 + int64(len(recs))*11
}

type recR struct {
	key   uint32
	klen  uint16
	value uint32
	vlen  uint16
}

func pagesR(b []byte) int64 {
	var recs []recR
	for p := 0; p < len(b)/4096; p++ {
		base := p * 4096
		for r := 0; r < u16(b, base); r++ {
			at := base + u16(b, base+2+2*r)
			klen := int(b[at])
			vat := at + 1 + klen
			recs = append(recs, recR{uint32(at + 1), uint16(klen), uint32(vat + 2), uint16(u16(b, vat))})
		}
	}
	var k1, sevens, vowels int64
	for _, r := range recs {
		if b[int(r.key)+1] == '1' {
			k1++
		}
		if b[int(r.key)+int(r.klen)-1] == '7' {
			sevens += int64(r.vlen)
		}
		if b[r.value] == 'a' {
			vowels++
		}
	}
	return k1 + sevens*3 + vowels*7 + int64(len(recs))*11
}

func main() {
	n, rounds, kernel := int64(200000), int64(20), "all"
	if len(os.Args) > 1 {
		n, _ = strconv.ParseInt(os.Args[1], 10, 64)
	}
	if len(os.Args) > 2 {
		rounds, _ = strconv.ParseInt(os.Args[2], 10, 64)
	}
	if len(os.Args) > 3 {
		kernel = os.Args[3]
	}
	input := func(k string) []byte {
		switch k {
		case "logs":
			return logsInput(n)
		case "json":
			return jsonInput(n / 2)
		}
		return pagesInput(n / 50)
	}
	run := func(f func([]byte) int64, b []byte) int64 {
		x := int64(0)
		for r := int64(0); r < rounds; r++ {
			x += f(b)
		}
		return x
	}
	all := []struct {
		name string
		f, g func([]byte) int64
	}{{"logs", logs, logsR}, {"json", json, jsonR}, {"pages", pages, pagesR}}
	for _, k := range all {
		if kernel == "all" {
			b := input(k.name)
			fmt.Println(len(b))
			fmt.Println(run(k.f, b))
			fmt.Println(run(k.g, b))
		} else if kernel == k.name || kernel == k.name+"_r" {
			b := input(k.name)
			f := k.f
			if kernel != k.name {
				f = k.g
			}
			fmt.Println(len(b))
			fmt.Println(run(f, b))
		}
	}
}
