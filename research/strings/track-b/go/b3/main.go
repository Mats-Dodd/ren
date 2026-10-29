// B3 Go twin: `b3 <json|logs|http> <datadir>`: strings.Builder (one for
// the whole output; one per response for http), the same hand itoa.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

func itoa(b *strings.Builder, x int64) {
	var t [24]byte
	n := 0
	neg := x < 0
	u := uint64(x)
	if neg {
		u = uint64(-x)
	}
	for {
		t[n] = byte('0' + u%10)
		n++
		u /= 10
		if u == 0 {
			break
		}
	}
	if neg {
		b.WriteByte('-')
	}
	for n > 0 {
		n--
		b.WriteByte(t[n])
	}
}
func js(b *strings.Builder, x string) {
	b.WriteByte('"')
	run := 0
	for i := 0; i < len(x); i++ {
		c := x[i]
		if c == '"' || c == '\\' || c < 0x20 {
			b.WriteString(x[run:i])
			if c == '"' {
				b.WriteString("\\\"")
			} else {
				b.WriteString("\\\\")
			}
			run = i + 1
		}
	}
	b.WriteString(x[run:])
	b.WriteByte('"')
}

func main() {
	w, dir := os.Args[1], os.Args[2]
	out, _ := os.OpenFile("/dev/null", os.O_WRONLY, 0)
	written := 0
	switch w {
	case "json":
		bs, _ := os.ReadFile(dir + "/people.csv")
		type P struct {
			id, score   int64
			name, email string
			tags        []string
		}
		var ps []P
		for _, l := range strings.Split(strings.TrimSuffix(string(bs), "\n"), "\n") {
			f := strings.Split(l, "\t")
			id, _ := strconv.ParseInt(f[0], 10, 64)
			sc, _ := strconv.ParseInt(f[3], 10, 64)
			var tags []string
			for _, t := range strings.Split(f[4], ";") {
				if t != "" {
					tags = append(tags, t)
				}
			}
			ps = append(ps, P{id, sc, f[1], f[2], tags})
		}
		t0 := time.Now()
		var b strings.Builder
		b.WriteByte('[')
		for r, x := range ps {
			if r > 0 {
				b.WriteByte(',')
			}
			b.WriteString("{\"id\":")
			itoa(&b, x.id)
			b.WriteString(",\"name\":")
			js(&b, x.name)
			b.WriteString(",\"email\":")
			js(&b, x.email)
			b.WriteString(",\"score\":")
			itoa(&b, x.score)
			b.WriteString(",\"tags\":[")
			for t, tag := range x.tags {
				if t > 0 {
					b.WriteByte(',')
				}
				js(&b, tag)
			}
			b.WriteString("]}")
		}
		b.WriteByte(']')
		n, _ := out.WriteString(b.String())
		written += n
		fmt.Printf("check=%d,%d\ntotal_ns=%d\n", len(ps), written, time.Since(t0).Nanoseconds())
	case "logs":
		bs, _ := os.ReadFile(dir + "/logs.txt")
		var rs [][]string
		for _, l := range strings.Split(strings.TrimSuffix(string(bs), "\n"), "\n") {
			rs = append(rs, strings.SplitN(l, " ", 8))
		}
		t0 := time.Now()
		var b strings.Builder
		for _, f := range rs {
			st, _ := strconv.ParseInt(f[5], 10, 64)
			du, _ := strconv.ParseInt(f[6][:len(f[6])-2], 10, 64)
			b.WriteString("ts=")
			b.WriteString(f[0])
			b.WriteString(" level=")
			b.WriteString(f[1])
			b.WriteString(" svc=")
			b.WriteString(f[2])
			b.WriteString(" method=")
			b.WriteString(f[3])
			b.WriteString(" path=\"")
			b.WriteString(f[4])
			b.WriteString("\" status=")
			itoa(&b, st)
			b.WriteString(" dur_ms=")
			itoa(&b, du)
			b.WriteString(" req_id=")
			b.WriteString(f[7][7:])
			b.WriteByte('\n')
		}
		n, _ := out.WriteString(b.String())
		written += n
		fmt.Printf("check=%d,%d\ntotal_ns=%d\n", len(rs), written, time.Since(t0).Nanoseconds())
	default:
		bs, _ := os.ReadFile(dir + "/body.html")
		body := string(bs)
		bl := int64(len(body))
		h1 := "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
		h2 := "\r\nDate: Thu, 29 Oct 2026 09:05:00 GMT\r\nServer: ren\r\nX-Request-Id: "
		h3 := "\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
		t0 := time.Now()
		for r := int64(0); r < 100000; r++ {
			ln := 512 + (r*7919)%1024
			at := (r * 104729) % (bl - ln)
			var b strings.Builder
			b.WriteString(h1)
			itoa(&b, ln)
			b.WriteString(h2)
			itoa(&b, 1000000007*r%9999991)
			b.WriteString(h3)
			b.WriteString(body[at : at+ln])
			n, _ := out.WriteString(b.String())
			written += n
		}
		fmt.Printf("check=%d,%d\ntotal_ns=%d\n", 100000, written, time.Since(t0).Nanoseconds())
	}
	fmt.Println("variant=go-builder")
}
