// B2 Go twin: `b2 <datadir> <share|clone>`. A Go substring shares its
// input and the GC keeps the whole input alive while it's reachable: the
// "always share" policy; clone is strings.Clone on keep.
package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

func main() {
	dir, clone := os.Args[1], os.Args[2] == "clone"
	t0 := time.Now()
	m := map[string]int64{}
	var order []string
	line := 0
	for c := 0; c < 64; c++ {
		b, err := os.ReadFile(fmt.Sprintf("%s/big/%03d.txt", dir, c))
		if err != nil {
			panic(err)
		}
		s := string(b)
		b = nil
		for i := 0; i < len(s); {
			j := i + strings.IndexByte(s[i:], '\n')
			if line%268 == 0 {
				k := s[i : i+strings.IndexByte(s[i:j], ' ')]
				if _, ok := m[k]; ok {
					m[k]++
				} else {
					if clone {
						k = strings.Clone(k)
					}
					m[k] = 1
					order = append(order, k)
				}
			}
			line++
			i = j + 1
		}
	}
	t := time.Since(t0).Nanoseconds()
	total := 0
	for k := range m {
		total += len(k)
	}
	fmt.Printf("check=%d,%d,%d\ntotal_ns=%d\nrepr=go-%s\n", len(m), total, line, t, os.Args[2])
}
