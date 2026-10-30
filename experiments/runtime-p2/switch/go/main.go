// Go twin of the single runtime's task switch: GOMAXPROCS=1, goroutines,
// channels, sync.WaitGroup and sync.Mutex, as a Go programmer writes them.
package main

import (
	"flag"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type res struct {
	ns, extra, objs, bytes float64
	ok                     bool
}

func pingpong(n uint64) (uint64, uint64) {
	ping, pong := make(chan uint64, 1), make(chan uint64, 1)
	go func() {
		for i := uint64(0); i < n; i++ {
			v := <-ping
			pong <- v + 1
		}
	}()
	var sum uint64
	for i := uint64(0); i < n; i++ {
		ping <- i
		sum += <-pong
	}
	return sum, n * (n + 1) / 2
}

func spawnJoin(n uint64) (uint64, uint64) {
	var wg sync.WaitGroup
	var sum atomic.Uint64
	for i := uint64(0); i < n; i++ {
		wg.Add(1)
		go func() { sum.Add(1); wg.Done() }()
		wg.Wait()
	}
	return sum.Load(), n
}

// A scope with a limit: a buffered channel as the semaphore (errgroup.SetLimit's shape).
func spawnBatch(n, max uint64) (uint64, uint64) {
	var wg sync.WaitGroup
	var sum atomic.Uint64
	sem := make(chan struct{}, max)
	for i := uint64(0); i < n; i++ {
		sem <- struct{}{}
		wg.Add(1)
		go func() { sum.Add(1); <-sem; wg.Done() }()
	}
	wg.Wait()
	return sum.Load(), n
}

var parkSpawnNs, parkBytes float64

func park(n uint64) (float64, uint64, uint64) {
	var ms0, ms1 runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&ms0)
	t0 := time.Now()
	gate := make(chan struct{})
	var wg sync.WaitGroup
	var mu sync.Mutex
	var count uint64
	var parked atomic.Uint64
	wg.Add(int(n))
	for i := uint64(0); i < n; i++ {
		go func() {
			parked.Add(1)
			<-gate
			mu.Lock()
			count++
			mu.Unlock()
			wg.Done()
		}()
	}
	for parked.Load() < n { // Async.tick: let every goroutine run until it blocks
		runtime.Gosched()
	}
	runtime.Gosched()
	t1 := time.Now()
	runtime.ReadMemStats(&ms1)
	t1b := time.Now()
	close(gate)
	wg.Wait()
	wake := float64(time.Since(t1b).Nanoseconds()) / float64(n)
	parkSpawnNs = float64(t1.Sub(t0).Nanoseconds()) / float64(n)
	used := func(m *runtime.MemStats) float64 { return float64(m.StackInuse + m.HeapInuse) }
	parkBytes = (used(&ms1) - used(&ms0)) / float64(n)
	return wake, count, n
}

func fanout(n uint64, yield bool) (uint64, uint64) {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var c uint64
	wg.Add(int(n))
	for i := uint64(0); i < n; i++ {
		go func(w uint64) {
			for k := uint64(0); k < 10; k++ {
				mu.Lock()
				c += w + k
				mu.Unlock()
				if yield {
					runtime.Gosched()
				}
			}
			wg.Done()
		}(i)
	}
	wg.Wait()
	return c, 10*(n*(n-1)/2) + 45*n
}

func runOnce(bench string, n, max uint64) res {
	var m0, m1 runtime.MemStats
	runtime.ReadMemStats(&m0)
	ops := n
	t0 := time.Now()
	var got, want uint64
	var r res
	switch bench {
	case "pingpong":
		got, want = pingpong(n)
	case "spawn_join":
		got, want = spawnJoin(n)
	case "spawn_batch":
		got, want = spawnBatch(n, max)
	case "park":
		r.ns, got, want = park(n)
		r.extra, r.bytes = parkSpawnNs, parkBytes
	case "fanout", "fanout_yield":
		got, want = fanout(n, bench == "fanout_yield")
		ops = 10 * n
	default:
		fmt.Fprintln(os.Stderr, "go: no bench", bench)
		os.Exit(2)
	}
	total := float64(time.Since(t0).Nanoseconds())
	runtime.ReadMemStats(&m1)
	if bench != "park" {
		r.ns, r.extra = total/float64(ops), total/float64(n)
	}
	r.objs = float64(m1.Mallocs-m0.Mallocs) / float64(ops)
	r.ok = got == want
	if !r.ok {
		fmt.Fprintf(os.Stderr, "FAIL go %s got=%d want=%d\n", bench, got, want)
	}
	return r
}

func main() {
	runtime.GOMAXPROCS(1)
	debug.SetGCPercent(100)
	bench := flag.String("bench", "pingpong", "")
	n := flag.Uint64("n", 1000000, "")
	max := flag.Uint64("max", 64, "")
	reps := flag.Int("reps", 7, "")
	check := flag.Bool("check", false, "")
	flag.Parse()
	if *check {
		ok := true
		for _, b := range []string{"pingpong", "spawn_join", "spawn_batch", "park", "fanout", "fanout_yield"} {
			nn := uint64(1000)
			if b[0] == 'f' {
				nn = 100
			}
			r := runOnce(b, nn, 64)
			s := "ok"
			if !r.ok {
				s, ok = "FAIL", false
			}
			fmt.Printf("CHECK lang=go bench=%s n=%d %s\n", b, nn, s)
		}
		if !ok {
			os.Exit(1)
		}
		return
	}
	ns, ex := make([]float64, *reps), make([]float64, *reps)
	var r0 res
	ok := true
	for i := 0; i < *reps; i++ {
		r := runOnce(*bench, *n, *max)
		if i == 0 {
			r0 = r
		}
		ns[i], ex[i], ok = r.ns, r.extra, ok && r.ok
	}
	mn, mx := ns[0], ns[0]
	rl := make([]string, len(ns))
	for i, v := range ns {
		if v < mn {
			mn = v
		}
		if v > mx {
			mx = v
		}
		rl[i] = fmt.Sprintf("%.2f", v)
	}
	med := func(v []float64) float64 {
		s := append([]float64(nil), v...)
		sort.Float64s(s)
		if len(s)%2 == 1 {
			return s[len(s)/2]
		}
		return (s[len(s)/2-1] + s[len(s)/2]) / 2
	}
	st := "ok"
	if !ok {
		st = "FAIL"
	}
	fmt.Printf("SWITCH lang=go bench=%s n=%d max=%d reps=%d ns_per_op=%.2f min_ns_per_op=%.2f "+
		"extra_ns=%.2f heap_allocs_per_op=%.4f sys_allocs_per_op=0 bytes_per_task=%.1f "+
		"footprint_per_task=0 task_header=0 gomaxprocs=%d max_ns_per_op=%.2f reps_ns=%s check=%s\n",
		*bench, *n, *max, *reps, med(ns), mn, med(ex), r0.objs, r0.bytes, runtime.GOMAXPROCS(0),
		mx, strings.Join(rl, ","), st)
	if !ok {
		os.Exit(1)
	}
}
