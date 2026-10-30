// The strings benchmark's Go twin (bench.ren says what each workload
// is): `main <workload> <n> <rounds>`, as the Rust twin, which says what
// each workload and its arguments are. The inputs are made byte for
// byte as gen.ren makes them; slices are substrings of the input, which
// share it; maps are Go's `map[string]int64` (`map_std` and `group_std`
// are the same as `map` and `group` here); output is built with a
// `strings.Builder`; `utf8.Valid` validates. One goroutine.
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// ---- the inputs: gen.c's, each from the generator's state where gen.c starts it ----

type rng uint64

func (g *rng) next() uint64 {
	*g += 0x9e3779b97f4a7c15
	z := uint64(*g)
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

func (g *rng) r(n uint64) uint64 { return g.next() % n }
func (g *rng) p(pct uint64) bool { return g.r(100) < pct }

const (
	tokSeed    = 2685821657736338717
	keysSeed   = 1501143529475956227
	sortSeed   = 11280350821882103235
	rowsSeed   = 3516444820516554288
	logsSeed   = 12666297937331212984
	peopleSeed = 3851254842298927852
)

var words = []string{"user", "id", "get", "set", "count", "item", "list", "map", "node", "value",
	"buf", "len", "next", "prev", "data", "key", "index", "name", "path", "time", "size", "read",
	"write", "parse", "token", "state", "error", "result", "config", "server", "client", "request",
	"response", "handler", "cache", "queue", "event", "stream", "frame", "table", "pool", "array",
	"bytes", "string", "order", "account", "price", "total", "line", "file", "entry", "temp",
	"flag", "mode", "kind", "type", "ref", "ptr", "ctx", "cur", "pos", "off", "max", "min"}
var keywords = []string{"let", "fn", "if", "else", "return", "for", "in", "match", "var", "while"}
var syllables = []string{"san", "por", "ber", "lin", "mad", "rid", "tok", "yo", "lon", "don",
	"par", "is", "osa", "ka", "new", "york", "chi", "ca", "go", "sao", "pau", "lo", "rio", "mel",
	"bour", "ne", "syd", "ney"}

func word(g *rng) string { return words[g.r(64)] }

func ident(g *rng) string {
	parts := 1 + g.r(3)
	var o strings.Builder
	for i := uint64(0); i < parts; i++ {
		if i > 0 {
			o.WriteByte('_')
		}
		o.WriteString(word(g))
	}
	if g.p(20) {
		o.WriteString(strconv.FormatUint(g.r(100), 10))
	}
	return o.String()
}

func key(g *rng, kind uint64) string {
	if kind < 60 {
		return ident(g)
	} else if kind < 85 {
		w := word(g)
		a := ident(g)
		b := ident(g)
		return w + "." + a + "." + b
	}
	v := 1 + g.r(2)
	w := word(g)
	id := g.r(1000000)
	a := ident(g)
	page := g.r(50)
	return fmt.Sprintf("https://api.example.com/v%d/%s/%d/%s?page=%d", v, w, id, a, page)
}

func tokInput(n int64) string {
	g := rng(tokSeed)
	var f strings.Builder
	lits := []string{"hello, world", "café au lait", "日本語", "a longer string literal with several words in it", "ok"}
	toks := int64(0)
	for toks < n {
		form := g.r(4)
		switch form {
		case 0:
			// gen.c prints its first `ident(a)` after the second has
			// overwritten it, so both are the second
			ident(&g)
			b := ident(&g)
			k := ident(&g)
			x := g.r(100000)
			a := ident(&g)
			fmt.Fprintf(&f, "let %s = %s(%s, %d) + %s;\n", a, b, k, x, a)
			toks += 12
		case 1:
			a := ident(&g)
			b := ident(&g)
			x := g.r(1000)
			k := ident(&g)
			fmt.Fprintf(&f, "if %s.%s >= %d {\n  return %s;\n}\n", a, b, x, k)
			toks += 11
		case 2:
			a := ident(&g)
			l := lits[g.r(5)]
			fmt.Fprintf(&f, "%s += \"%s\";\n", a, l)
			toks += 4
		default:
			kw := keywords[g.r(10)]
			a := ident(&g)
			b := ident(&g)
			k := ident(&g)
			fmt.Fprintf(&f, "%s %s = %s -> %s;\n", kw, a, b, k)
			toks += 6
		}
	}
	return f.String()
}

func keysInput(pool, lines int64) string {
	g := rng(keysSeed)
	ks := make([]string, 0, pool)
	for i := int64(0); i < pool; i++ {
		kind := g.r(100)
		ks = append(ks, key(&g, kind))
	}
	var f strings.Builder
	for i := int64(0); i < lines; i++ {
		var j uint64
		if g.p(80) {
			j = g.r(uint64(pool) / 10)
		} else {
			j = g.r(uint64(pool))
		}
		f.WriteString(ks[j])
		f.WriteByte('\n')
	}
	return f.String()
}

func sortInput(n int64) string {
	g := rng(sortSeed)
	var f strings.Builder
	for i := int64(0); i < n; i++ {
		kind := g.r(100)
		f.WriteString(key(&g, kind))
		f.WriteByte('\n')
	}
	return f.String()
}

func rowsInput(cities, rows int64) string {
	g := rng(rowsSeed)
	cs := make([]string, 0, cities)
	for i := int64(0); i < cities; i++ {
		a := ""
		n := 2 + g.r(4)
		for j := uint64(0); j < n; j++ {
			a += syllables[g.r(28)]
			if j == 1 && g.p(40) {
				a += " "
			}
		}
		a = strings.ToUpper(a[:1]) + a[1:]
		if g.p(5) {
			a += " é"
		}
		cs = append(cs, a+strconv.FormatInt(i%7, 10))
	}
	var f strings.Builder
	for i := int64(0); i < rows; i++ {
		c := cs[g.r(uint64(cities))]
		d := words[g.r(20)]
		x := g.r(100000)
		fmt.Fprintf(&f, "%s,%s,%d\n", c, d, x)
	}
	return f.String()
}

func logsInput(lines int64) string {
	g := rng(logsSeed)
	svc := []string{"api-gateway", "auth", "billing", "search", "orders", "inventory", "notify", "users"}
	lv := []string{"INFO", "WARN", "ERROR", "DEBUG"}
	meth := []string{"GET", "POST", "PUT", "DELETE"}
	var f strings.Builder
	for i := int64(0); i < lines; i++ {
		r := g.r(100)
		l := 3
		if r < 85 {
			l = 0
		} else if r < 95 {
			l = 1
		} else if r < 99 {
			l = 2
		}
		var path string
		switch g.r(5) {
		case 0:
			path = fmt.Sprintf("/v1/users/%d/orders", g.r(100000))
		case 1:
			path = fmt.Sprintf("/v2/items/%d", g.r(1000000))
		case 2:
			path = "/health"
		case 3:
			path = "/v1/search?q=" + word(&g)
		default:
			path = fmt.Sprintf("/v1/users/%d", g.r(100000))
		}
		status := 200
		if g.p(2) {
			status = 500
		} else if g.p(5) {
			status = 404
		}
		mm, ss, ms := g.r(60), g.r(60), g.r(1000)
		s := svc[g.r(8)]
		m := meth[g.r(4)]
		dur := 1 + g.r(2000)
		req := g.next()
		fmt.Fprintf(&f, "2026-10-29T09:%02d:%02d.%03dZ %s %s %s %s %d %dms req_id=%016x\n",
			mm, ss, ms, lv[l], s, m, path, status, dur, req)
	}
	return f.String()
}

func peopleInput(n int64) string {
	g := rng(peopleSeed)
	var f strings.Builder
	for i := int64(0); i < n; i++ {
		a := word(&g)
		b := word(&g)
		nm := strings.ToUpper(a[:1]) + a[1:] + " " + b
		if g.p(3) {
			nm += " \"jr\""
		}
		if g.p(5) {
			nm += " Muñoz"
		}
		e1, e2 := word(&g), word(&g)
		e3, score := g.r(1000), g.r(1000000)
		fmt.Fprintf(&f, "%d\t%s\t%s.%s%d@example.com\t%d\t", i, nm, e1, e2, e3, score)
		nt := g.r(4)
		for t := uint64(0); t < nt; t++ {
			if t > 0 {
				f.WriteByte(';')
			}
			f.WriteString(word(&g))
		}
		f.WriteByte('\n')
	}
	return f.String()
}

func utf8Input(kind string, n int) []byte {
	g := rng(42)
	o := make([]byte, 0, n+8)
	for len(o) < n-4 {
		r := g.next() % 100
		var c rune
		if r == 99 && g.next()&1 == 1 {
			c = '\n'
		} else if kind == "ascii" {
			if r < 15 {
				c = ' '
			} else {
				c = 'a' + rune(g.next()%26)
			}
		} else if kind == "cjk" {
			if r < 10 {
				c = ' '
			} else {
				c = 0x4e00 + rune(g.next()%20000)
			}
		} else if r < 98 {
			if r < 15 {
				c = ' '
			} else {
				c = 'a' + rune(g.next()%26)
			}
		} else if r < 99 {
			c = 0xe9
		} else {
			c = 0x65e5
		}
		o = utf8.AppendRune(o, c)
	}
	for len(o) < n {
		o = append(o, ' ')
	}
	return o
}

// ---- the kernels, each giving its check ----

func isLetter(c byte) bool { return c == '_' || (c|32)-'a' < 26 }
func isDigit(c byte) bool  { return c-'0' < 10 }

type tok struct {
	kind int64
	text string
}

func tokens(src string) string {
	n := len(src)
	var ts []tok
	i := 0
	for i < n {
		c := src[i]
		if c == ' ' || c == '\n' || c == '\t' {
			i++
			continue
		}
		j := i + 1
		var kind int64
		if isLetter(c) {
			for j < n && (isLetter(src[j]) || isDigit(src[j])) {
				j++
			}
			kind = 0
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
			if j < n && (((c == '=' || c == '!' || c == '<' || c == '>' || c == '+') && src[j] == '=') ||
				(c == '-' && src[j] == '>')) {
				j++
			}
			kind = 3
		}
		ts = append(ts, tok{kind, src[i:j]})
		i = j
	}
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
	return fmt.Sprintf("%d,%d,%d,%d", len(ts), returns, idents, total)
}

func lines(src string) []string {
	xs := strings.Split(src, "\n")
	return xs[:len(xs)-1]
}

func countKeys(src string) string {
	m := map[string]int64{}
	for _, k := range lines(src) {
		m[k]++
	}
	var sum int64
	for _, k := range lines(src) {
		sum += m[k]
	}
	return fmt.Sprintf("%d,%d", len(m), sum)
}

func sorting(src string) string {
	xs := lines(src)
	sort.Strings(xs)
	var check int64
	for k := 0; k < len(xs); k += 1000 {
		check += int64(len(xs[k]))*int64(k) + int64(xs[k][0])
	}
	return fmt.Sprintf("%d,%d", len(xs), check)
}

func digits(s string) int64 {
	var n int64
	for i := 0; i < len(s); i++ {
		n = n*10 + int64(s[i]-'0')
	}
	return n
}

func group(src string) string {
	m := map[string]int64{}
	for _, l := range lines(src) {
		c1 := strings.IndexByte(l, ',')
		k := strings.LastIndexByte(l, ',') + 1
		m[l[:c1]] += digits(l[k:])
	}
	var check, total int64
	for k, v := range m {
		check ^= int64(len(k))*1000003 + v
		total += v
	}
	return fmt.Sprintf("%d,%d,%d", len(m), total, check)
}

type rec struct {
	ts, level, svc, method, path, req string
	status, dur                       int64
}

func records(src string) []rec {
	var rs []rec
	for _, l := range lines(src) {
		f := strings.SplitN(l, " ", 8)
		rs = append(rs, rec{f[0], f[1], f[2], f[3], f[4], f[7][7:], digits(f[5]), digits(f[6][:len(f[6])-2])})
	}
	return rs
}

func logs(src string) string {
	rs := records(src)
	var errors, slow, users int64
	for i := range rs {
		r := &rs[i]
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
	return fmt.Sprintf("%d,%d,%d,%d", len(rs), errors, slow, users)
}

// ---- out: building output ----

type person struct {
	id, score   int64
	name, email string
	tags        []string
}

func people(src string, limit int64) []person {
	var ps []person
	for _, l := range lines(src) {
		if int64(len(ps)) >= limit {
			break
		}
		f := strings.Split(l, "\t")
		var tags []string
		for _, t := range strings.Split(f[4], ";") {
			if t != "" {
				tags = append(tags, t)
			}
		}
		ps = append(ps, person{digits(f[0]), digits(f[3]), f[1], f[2], tags})
	}
	return ps
}

func jsonStr(o *strings.Builder, s string) {
	o.WriteByte('"')
	run := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '"' || c == '\\' || c < 0x20 {
			o.WriteString(s[run:i])
			if c == '"' {
				o.WriteString("\\\"")
			} else {
				o.WriteString("\\\\")
			}
			run = i + 1
		}
	}
	o.WriteString(s[run:])
	o.WriteByte('"')
}

func outJSON(ps []person) string {
	var o strings.Builder
	var num [24]byte
	o.WriteByte('[')
	for r, x := range ps {
		if r > 0 {
			o.WriteByte(',')
		}
		o.WriteString("{\"id\":")
		o.Write(strconv.AppendInt(num[:0], x.id, 10))
		o.WriteString(",\"name\":")
		jsonStr(&o, x.name)
		o.WriteString(",\"email\":")
		jsonStr(&o, x.email)
		o.WriteString(",\"score\":")
		o.Write(strconv.AppendInt(num[:0], x.score, 10))
		o.WriteString(",\"tags\":[")
		for t, tag := range x.tags {
			if t > 0 {
				o.WriteByte(',')
			}
			jsonStr(&o, tag)
		}
		o.WriteString("]}")
	}
	o.WriteByte(']')
	return fmt.Sprintf("%d,%d", len(ps), len(o.String()))
}

func outLogs(rs []rec) string {
	var o strings.Builder
	var num [24]byte
	for i := range rs {
		r := &rs[i]
		o.WriteString("ts=")
		o.WriteString(r.ts)
		o.WriteString(" level=")
		o.WriteString(r.level)
		o.WriteString(" svc=")
		o.WriteString(r.svc)
		o.WriteString(" method=")
		o.WriteString(r.method)
		o.WriteString(" path=\"")
		o.WriteString(r.path)
		o.WriteString("\" status=")
		o.Write(strconv.AppendInt(num[:0], r.status, 10))
		o.WriteString(" dur_ms=")
		o.Write(strconv.AppendInt(num[:0], r.dur, 10))
		o.WriteString(" req_id=")
		o.WriteString(r.req)
		o.WriteByte('\n')
	}
	return fmt.Sprintf("%d,%d", len(rs), len(o.String()))
}

// gen.c's 2,000 cities at 1,000,000, and at least 4
func cities(n int64) int64 {
	if n >= 2000 {
		return n / 500
	}
	return 4
}

func main() {
	w := os.Args[1]
	n, _ := strconv.ParseInt(os.Args[2], 10, 64)
	rounds, _ := strconv.Atoi(os.Args[3])
	if strings.HasPrefix(w, "utf8_") {
		b := utf8Input(w[5:], int(n))
		fmt.Println(len(b))
		ok, total := 0, 0
		for i := 0; i < rounds; i++ {
			if utf8.Valid(b) {
				ok++
				total += len(b)
			}
		}
		fmt.Printf("%d,%d\n", ok, total)
		return
	}
	var src string
	switch w {
	case "tok":
		src = tokInput(n)
	case "map", "map_std":
		src = keysInput(n/5, 4*n)
	case "sort":
		src = sortInput(n)
	case "group", "group_std":
		src = rowsInput(cities(n), 5*n)
	case "logs", "out_logs":
		src = logsInput(n)
	case "out_json":
		src = peopleInput(n)
	default:
		panic("no workload " + w)
	}
	fmt.Println(len(src))
	var ps []person
	var rs []rec
	if w == "out_json" {
		ps = people(src, n)
	}
	if w == "out_logs" {
		rs = records(src)
	}
	for i := 0; i < rounds; i++ {
		var check string
		switch w {
		case "tok":
			check = tokens(src)
		case "map", "map_std":
			check = countKeys(src)
		case "sort":
			check = sorting(src)
		case "group", "group_std":
			check = group(src)
		case "logs":
			check = logs(src)
		case "out_json":
			check = outJSON(ps)
		default:
			check = outLogs(rs)
		}
		fmt.Println(check)
	}
}
