// K1b threaded harness, Rust. Mirrors c/k1b.c: the same three variants, the
// same atomics and orderings, the same streams, seeds, timing and checks.
// UnsafeCell stands in for the C's plain fields guarded by a lock. See
// ../../PLAN.md and the long comment at the top of c/k1b.c.
//
// (The original rust/src/bin/k1b.rs was lost: experiments/.gitignore's `bin/`
// also matched rust/src/bin/, so it was never committed. This is a rewrite
// from c/k1b.c, kept outside src/bin/ for that reason.)
mod common;
mod plat;

use common::*;
use plat::*;
use std::cell::UnsafeCell;
use std::sync::atomic::Ordering::*;
use std::sync::atomic::{AtomicI32, AtomicU32, AtomicU64};

const STREAM: u64 = 1 << 19;
const EV: u32 = 0x8000_0000;
const V_A: i32 = 0;
const V_B: i32 = 1;
const V_C: i32 = 2;
const VNAMES: [&str; 3] = ["a_lru", "b_sampled", "c_clock"];

#[inline(always)]
fn get<T: Copy>(c: &UnsafeCell<T>) -> T {
    unsafe { *c.get() }
}
#[inline(always)]
fn put<T>(c: &UnsafeCell<T>, v: T) {
    unsafe { *c.get() = v }
}

// One instance per 128-byte line: its lock, pin word, key, use stamp, state.
#[repr(C, align(128))]
struct Inst {
    lock: Lock,
    ctl: AtomicU32,   // b, c: pins | EV. a: pins, guarded by the partition lock
    key: AtomicU64,
    stamp: AtomicU64, // b: last-use stamp. c: use bit. a: unused
    state: UnsafeCell<u64>,
    prev: UnsafeCell<i32>, // a: LRU links, guarded by the partition lock
    next: UnsafeCell<i32>,
}

// Read-only after build, on its own line.
#[repr(C, align(128))]
struct Table {
    mask: u32,
    keys: Box<[AtomicU64]>,
    idx: Box<[AtomicI32]>,
}

#[repr(C, align(128))]
struct Shard {
    lock: Lock,
    count: UnsafeCell<u32>,
    cap: u32,
    head: UnsafeCell<i32>,
    tail: UnsafeCell<i32>,
    t: Table,
}

struct Fam {
    variant: i32,
    k: i32,
    os: bool,
    nparts: u32,
    maxn: u32,
    inst: Box<[Inst]>,
    sh: Box<[Shard]>,
    nalloc: AtomicU32,
    hand: AtomicU64,
    evicted_sum: AtomicU64,
    evictions: AtomicU64,
}
unsafe impl Sync for Fam {}

#[repr(C, align(128))]
struct Worker {
    ops: u64,
    hits: u64,
    misses: u64,
    retries: u64,
    rng: u64,
    now: u64,
    pos: u64,
    hist: Vec<u32>,
}

fn fail(msg: String) -> ! {
    eprintln!("FAIL: {}", msg);
    std::process::exit(1)
}

impl Fam {
    fn build(variant: i32, k: i32, os: bool, parts: u32, max: u32) -> Fam {
        let inst: Vec<Inst> = (0..max)
            .map(|_| Inst {
                lock: Lock::new(),
                ctl: AtomicU32::new(if variant == V_A { 0 } else { EV }), // b, c: unallocated slots are claimed
                key: AtomicU64::new(0),
                stamp: AtomicU64::new(0),
                state: UnsafeCell::new(0),
                prev: UnsafeCell::new(-1),
                next: UnsafeCell::new(-1),
            })
            .collect();
        let sz = pow2_at_least((max / parts) * 2 + 256) as usize;
        let sh: Vec<Shard> = (0..parts)
            .map(|j| Shard {
                lock: Lock::new(),
                count: UnsafeCell::new(0),
                cap: max / parts + (j < max % parts) as u32,
                head: UnsafeCell::new(-1),
                tail: UnsafeCell::new(-1),
                t: Table {
                    mask: sz as u32 - 1,
                    keys: (0..sz).map(|_| AtomicU64::new(0)).collect(),
                    idx: (0..sz).map(|_| AtomicI32::new(0)).collect(),
                },
            })
            .collect();
        Fam {
            variant,
            k,
            os,
            nparts: parts,
            maxn: max,
            inst: inst.into_boxed_slice(),
            sh: sh.into_boxed_slice(),
            nalloc: AtomicU32::new(0),
            hand: AtomicU64::new(0),
            evicted_sum: AtomicU64::new(0),
            evictions: AtomicU64::new(0),
        }
    }

    #[inline(always)]
    fn shard(&self, h: u64) -> &Shard {
        &self.sh[part_of(h, self.nparts) as usize]
    }

    #[inline(always)]
    fn tab_find(&self, p: &Shard, k: u64, h: u64) -> i32 {
        let m = p.t.mask;
        let mut s = h as u32 & m;
        loop {
            let x = p.t.keys[s as usize].load(Acquire);
            if x == k {
                return p.t.idx[s as usize].load(Relaxed);
            }
            if x == 0 {
                return -1;
            }
            s = (s + 1) & m;
        }
    }
    fn tab_insert(&self, p: &Shard, k: u64, h: u64, i: i32) {
        let m = p.t.mask;
        let mut s = h as u32 & m;
        while p.t.keys[s as usize].load(Relaxed) != 0 {
            s = (s + 1) & m;
        }
        p.t.idx[s as usize].store(i, Relaxed);
        p.t.keys[s as usize].store(k, Release);
        let c = get(&p.count) + 1;
        put(&p.count, c);
        if c as u64 * 4 > (m as u64 + 1) * 3 {
            eprintln!("FAIL: shard table over 3/4");
            std::process::abort();
        }
    }
    fn tab_delete(&self, p: &Shard, k: u64, h: u64) {
        let m = p.t.mask;
        let mut s = h as u32 & m;
        while p.t.keys[s as usize].load(Relaxed) != k {
            if p.t.keys[s as usize].load(Relaxed) == 0 {
                eprintln!("FAIL: delete of absent key");
                std::process::abort();
            }
            s = (s + 1) & m;
        }
        let mut j = s;
        loop {
            j = (j + 1) & m;
            let x = p.t.keys[j as usize].load(Relaxed);
            if x == 0 {
                break;
            }
            let home = mix64(x) as u32 & m;
            if (j.wrapping_sub(home) & m) >= (j.wrapping_sub(s) & m) {
                // x may move back to s
                p.t.idx[s as usize].store(p.t.idx[j as usize].load(Relaxed), Relaxed);
                p.t.keys[s as usize].store(x, Release);
                s = j;
            }
        }
        p.t.keys[s as usize].store(0, Release);
        put(&p.count, get(&p.count) - 1);
    }

    fn lru_remove(&self, p: &Shard, i: i32) {
        let a = &self.inst[i as usize];
        let (pv, nx) = (get(&a.prev), get(&a.next));
        if pv >= 0 { put(&self.inst[pv as usize].next, nx) } else { put(&p.head, nx) }
        if nx >= 0 { put(&self.inst[nx as usize].prev, pv) } else { put(&p.tail, pv) }
        put(&a.prev, -1);
        put(&a.next, -1);
    }
    fn lru_push(&self, p: &Shard, i: i32) {
        let a = &self.inst[i as usize];
        let hd = get(&p.head);
        put(&a.prev, -1);
        put(&a.next, hd);
        if hd >= 0 { put(&self.inst[hd as usize].prev, i) } else { put(&p.tail, i) }
        put(&p.head, i);
    }

    // ---- a: phase 1's partition + exact LRU ----------------------------------
    #[inline(always)]
    fn at_a(&self, w: &mut Worker, k: u64) {
        let os = self.os;
        let h = mix64(k);
        let p = self.shard(h);
        p.lock.lock(os);
        let mut s = self.tab_find(p, k, h);
        if s >= 0 {
            w.hits += 1;
            let a = &self.inst[s as usize];
            let pins = a.ctl.load(Relaxed);
            a.ctl.store(pins + 1, Relaxed);
            if pins == 0 {
                self.lru_remove(p, s);
            }
        } else {
            w.misses += 1;
            if get(&p.count) < p.cap {
                s = self.nalloc.fetch_add(1, Relaxed) as i32;
            } else {
                s = get(&p.tail); // the least recently released evictable instance
                if s < 0 {
                    eprintln!("FAIL: partition full of pinned instances");
                    std::process::abort();
                }
                self.lru_remove(p, s);
                let v = &self.inst[s as usize];
                let vk = v.key.load(Relaxed);
                self.tab_delete(p, vk, mix64(vk));
                v.lock.lock(os); // finally runs on the caller's task, holding the victim
                self.evicted_sum.fetch_add(get(&v.state), Relaxed);
                v.lock.unlock(os);
                self.evictions.fetch_add(1, Relaxed);
            }
            let a = &self.inst[s as usize];
            a.lock.lock(os);
            put(&a.state, 0); // setup
            a.lock.unlock(os);
            a.key.store(k, Relaxed);
            a.ctl.store(1, Relaxed);
            self.tab_insert(p, k, h, s);
        }
        p.lock.unlock(os);
        let a = &self.inst[s as usize];
        a.lock.lock(os); // the body: one operation
        put(&a.state, get(&a.state) + 1);
        a.lock.unlock(os);
        p.lock.lock(os);
        let pins = a.ctl.load(Relaxed) - 1;
        a.ctl.store(pins, Relaxed);
        if pins == 0 {
            self.lru_push(p, s);
        }
        p.lock.unlock(os);
    }

    // ---- b, c: use stamps or bits ----------------------------------------------
    #[inline(always)]
    fn rnd_slot(w: &mut Worker, n: u32) -> u32 {
        (((splitmix64(&mut w.rng) >> 32) * n as u64) >> 32) as u32
    }

    // A slot with EV set and no pins, whose key is gone from its table and
    // whose finally has run. Holds shard p's lock throughout.
    fn evict_one(&self, w: &mut Worker, p: &Shard) -> i32 {
        let os = self.os;
        loop {
            let mut v: i32 = -1;
            if self.variant == V_B {
                let mut best = u64::MAX;
                for _ in 0..self.k {
                    let s = Self::rnd_slot(w, self.maxn);
                    let a = &self.inst[s as usize];
                    if a.ctl.load(Relaxed) != 0 {
                        continue; // pinned or being evicted
                    }
                    let st = a.stamp.load(Relaxed);
                    if st < best {
                        best = st;
                        v = s as i32;
                    }
                }
                if v < 0 {
                    w.retries += 1;
                    continue;
                }
            } else {
                loop {
                    let s = (self.hand.fetch_add(1, Relaxed) % self.maxn as u64) as usize;
                    let a = &self.inst[s];
                    if a.ctl.load(Relaxed) != 0 {
                        continue;
                    }
                    if a.stamp.load(Relaxed) != 0 {
                        a.stamp.store(0, Relaxed);
                        continue;
                    }
                    v = s as i32;
                    break;
                }
            }
            let a = &self.inst[v as usize];
            if a.ctl.compare_exchange(0, EV, AcqRel, Relaxed).is_err() {
                w.retries += 1;
                continue;
            }
            let vk = a.key.load(Relaxed);
            let vh = mix64(vk);
            let q = self.shard(vh);
            let other = !std::ptr::eq(q, p);
            if other && !q.lock.try_lock(os) {
                // never wait holding a lock: give it back, choose again
                a.ctl.fetch_and(!EV, Release);
                w.retries += 1;
                continue;
            }
            self.tab_delete(q, vk, vh);
            if other {
                q.lock.unlock(os);
            }
            a.lock.lock(os); // finally
            self.evicted_sum.fetch_add(get(&a.state), Relaxed);
            a.lock.unlock(os);
            self.evictions.fetch_add(1, Relaxed);
            return v;
        }
    }

    // The miss path. k's slot, pinned, or -1 to retry the lookup.
    fn miss_bc(&self, w: &mut Worker, p: &Shard, k: u64, h: u64) -> i32 {
        let os = self.os;
        p.lock.lock(os);
        let mut s = self.tab_find(p, k, h);
        if s >= 0 {
            // someone made it, or the lock-free read missed spuriously
            let a = &self.inst[s as usize];
            let c = a.ctl.fetch_add(1, Acquire);
            p.lock.unlock(os);
            if c & EV != 0 {
                a.ctl.fetch_sub(1, Relaxed);
                return -1;
            }
            w.hits += 1;
            return s;
        }
        w.misses += 1;
        let mut n = self.nalloc.load(Relaxed);
        while n < self.maxn {
            match self.nalloc.compare_exchange_weak(n, n + 1, Relaxed, Relaxed) {
                Ok(_) => break,
                Err(x) => n = x,
            }
        }
        s = if n < self.maxn { n as i32 } else { self.evict_one(w, p) }; // either way we hold EV on s
        let a = &self.inst[s as usize];
        a.lock.lock(os);
        put(&a.state, 0); // setup
        a.lock.unlock(os);
        a.stamp.store(if self.variant == V_B { w.now } else { 1 }, Relaxed); // making it is a use
        a.key.store(k, Relaxed);
        self.tab_insert(p, k, h, s);
        a.ctl.fetch_add(1, Relaxed); // our pin
        a.ctl.fetch_and(!EV, Release); // publish
        p.lock.unlock(os);
        s
    }

    #[inline(always)]
    fn at_bc(&self, w: &mut Worker, k: u64) {
        let os = self.os;
        let h = mix64(k);
        let p = self.shard(h);
        let mut s;
        loop {
            s = self.tab_find(p, k, h);
            if s < 0 {
                s = self.miss_bc(w, p, k, h);
                if s >= 0 {
                    break;
                }
                w.retries += 1;
                continue;
            }
            let a = &self.inst[s as usize];
            let c = a.ctl.fetch_add(1, Acquire);
            if c & EV != 0 || a.key.load(Relaxed) != k {
                a.ctl.fetch_sub(1, Release);
                w.retries += 1;
                continue;
            }
            w.hits += 1;
            break;
        }
        let a = &self.inst[s as usize];
        a.lock.lock(os); // the body: one operation, and the take records the use
        put(&a.state, get(&a.state) + 1);
        a.stamp.store(if self.variant == V_B { w.now } else { 1 }, Relaxed);
        a.lock.unlock(os);
        a.ctl.fetch_sub(1, Release); // unpin
    }

    #[inline(always)]
    fn at(&self, w: &mut Worker, k: u64) {
        if self.variant == V_A { self.at_a(w, k) } else { self.at_bc(w, k) }
    }

    // Checks at rest: see verify() in c/k1b.c.
    fn verify(&self, total_ops: u64) {
        let n = self.nalloc.load(Relaxed);
        if n > self.maxn { fail(format!("nalloc {} > max {}", n, self.maxn)) }
        let (mut st, mut listed, mut entries) = (0u64, 0u64, 0u64);
        for i in 0..n {
            let a = &self.inst[i as usize];
            st += get(&a.state);
            let c = a.ctl.load(Relaxed);
            if c != 0 { fail(format!("slot {} ctl {:x} at rest", i, c)) }
            let k = a.key.load(Relaxed);
            let h = mix64(k);
            if k == 0 { fail(format!("slot {} has no key", i)) }
            if self.tab_find(self.shard(h), k, h) != i as i32 { fail(format!("slot {} key {} not mapped to it", i, k)) }
        }
        let ev = self.evicted_sum.load(Relaxed);
        if st + ev != total_ops { fail(format!("live {} + evicted {} != ops {}", st, ev, total_ops)) }
        for (j, p) in self.sh.iter().enumerate() {
            let c = p.t.keys.iter().filter(|x| x.load(Relaxed) != 0).count() as u32;
            if c != get(&p.count) { fail(format!("shard {} has {} entries, count {}", j, c, get(&p.count))) }
            entries += c as u64;
            if self.variant == V_A {
                if get(&p.count) > p.cap { fail(format!("partition {} over its cap", j)) }
                let mut l = 0u32;
                let mut i = get(&p.head);
                while i >= 0 {
                    l += 1;
                    i = get(&self.inst[i as usize].next);
                }
                if l != get(&p.count) { fail(format!("partition {} lru {} != {}", j, l, get(&p.count))) }
                listed += l as u64;
            }
        }
        if entries != n as u64 { fail(format!("table entries {} != slots {}", entries, n)) }
        if self.variant == V_A && listed != n as u64 { fail(format!("listed {} != {}", listed, n)) }
    }
}

static READY: AtomicU32 = AtomicU32::new(0);
static GO: AtomicU32 = AtomicU32::new(0);
static STOP: AtomicU32 = AtomicU32::new(0);

fn run_worker(f: &Fam, w: &mut Worker, st: &[u32], qos: i32) {
    set_qos(qos);
    let mut pos = w.pos;
    let mut ops = 0u64;
    READY.fetch_add(1, SeqCst);
    while GO.load(Acquire) == 0 {
        cpu_relax();
    }
    while STOP.load(Relaxed) == 0 {
        let t0 = clk_now();
        w.now = t0; // the runtime's per-worker clock, refreshed every 16 calls
        f.at(w, st[(pos & (STREAM - 1)) as usize] as u64);
        pos += 1;
        let dt = ((clk_now().wrapping_sub(t0)) >> HSHIFT) as usize;
        w.hist[if dt < HBUCKETS { dt } else { HBUCKETS - 1 }] += 1;
        for _ in 1..16 {
            f.at(w, st[(pos & (STREAM - 1)) as usize] as u64);
            pos += 1;
        }
        ops += 16;
    }
    w.ops = ops;
    w.pos = pos;
}

fn hist_pct(h: &[u64], total: u64, q: f64) -> f64 {
    let want = (q * total.wrapping_sub(1) as f64) as u64;
    let mut acc = 0u64;
    for (i, &c) in h.iter().enumerate() {
        acc += c;
        if acc > want {
            return i as f64;
        }
    }
    (HBUCKETS - 1) as f64
}

fn main() {
    let (mut workers, mut reps, mut ms, mut warm_ms, mut max, mut parts) = (4usize, 5usize, 200u64, -1i64, 10000u32, 0u32);
    let (mut uf, mut dist) = ("0.9".to_string(), "zipf99".to_string());
    let (mut variant, mut k, mut os, mut qos) = (V_B, 5i32, false, 0i32);
    for (a, v) in args() {
        match a.as_str() {
            "--variant" => {
                variant = match v.as_str() {
                    "a_lru" => V_A,
                    "b_sampled" => V_B,
                    "c_clock" => V_C,
                    _ => {
                        eprintln!("unknown variant {}", v);
                        std::process::exit(2)
                    }
                }
            }
            "--k" => k = v.parse().unwrap(),
            "--lock" => os = v == "os",
            "--dist" => dist = v,
            "--max" => max = v.parse().unwrap(),
            "--universe" => uf = v,
            "--parts" => parts = v.parse().unwrap(),
            "--workers" => workers = v.parse().unwrap(),
            "--reps" => reps = v.parse().unwrap(),
            "--ms" => ms = v.parse().unwrap(),
            "--warm-ms" => warm_ms = v.parse().unwrap(),
            "--qos" => qos = if v == "p" { 0 } else if v == "e" { 1 } else { 2 },
            _ => {
                eprintln!("unknown arg {}", a);
                std::process::exit(2)
            }
        }
    }
    if parts == 0 {
        parts = default_parts(max);
    }
    let warm_ms = if warm_ms < 0 { ms } else { warm_ms as u64 };
    let di = dist_of(&dist);
    let u = universe(&uf, max);
    let wl = Workload::new(di, u, max);
    let tick_ns = clk_tick_ns();
    let bucket_ns = tick_ns * (1u64 << HSHIFT) as f64;

    let nw = workers;
    let streams: Vec<Vec<u32>> = (0..nw)
        .map(|w| {
            let mut seed = 0x1234u64 + w as u64 * 0x9e3779b9;
            let mut cur = (wl.l as u64 * w as u64 / nw as u64) as u32;
            (0..STREAM).map(|_| wl.next(&mut seed, &mut cur)).collect()
        })
        .collect();
    let f = Fam::build(variant, k, os, parts, max);

    let mut ws: Vec<Worker> = (0..nw)
        .map(|w| Worker {
            ops: 0,
            hits: 0,
            misses: 0,
            retries: 0,
            rng: 0x5eed0000u64 + k as u64 * 0x10000 + w as u64,
            now: 0,
            pos: 0,
            hist: vec![0u32; HBUCKETS],
        })
        .collect();
    let (mut mops, mut p50, mut p99) = (vec![], vec![], vec![]);
    let (mut all_ops, mut t_hits, mut t_misses, mut t_ops, mut t_retries) = (0u64, 0u64, 0u64, 0u64, 0u64);
    let mut h = vec![0u64; HBUCKETS];
    for r in -1i64..reps as i64 {
        // rep -1 warms the family up, untimed
        let dur = if r < 0 { warm_ms } else { ms };
        if r < 0 && dur == 0 {
            continue;
        }
        READY.store(0, SeqCst);
        GO.store(0, SeqCst);
        STOP.store(0, SeqCst);
        for w in ws.iter_mut() {
            w.ops = 0;
            w.hits = 0;
            w.misses = 0;
            w.retries = 0;
            w.hist.iter_mut().for_each(|x| *x = 0);
        }
        let fr = &f;
        let (t0, t1) = std::thread::scope(|sc| {
            for (w, st) in ws.iter_mut().zip(streams.iter()) {
                sc.spawn(move || run_worker(fr, w, st, qos));
            }
            while (READY.load(SeqCst) as usize) < nw {
                std::thread::sleep(std::time::Duration::from_micros(100));
            }
            let t0 = wall();
            GO.store(1, Release);
            std::thread::sleep(std::time::Duration::from_millis(dur));
            STOP.store(1, SeqCst);
            (t0, wall())
        });
        let (mut total, mut hits, mut misses, mut hn) = (0u64, 0u64, 0u64, 0u64);
        h.iter_mut().for_each(|x| *x = 0);
        for w in ws.iter() {
            total += w.ops;
            hits += w.hits;
            misses += w.misses;
            if r >= 0 {
                t_retries += w.retries;
            }
            for (b, &c) in w.hist.iter().enumerate() {
                h[b] += c as u64;
                hn += c as u64;
            }
        }
        all_ops += total;
        if hits + misses != total {
            fail(format!("hits {} + misses {} != ops {}", hits, misses, total))
        }
        f.verify(all_ops);
        if r < 0 {
            continue;
        }
        t_hits += hits;
        t_misses += misses;
        t_ops += total;
        mops.push(total as f64 / (t1 - t0).as_nanos() as f64 * 1e3);
        p50.push(hist_pct(&h, hn, 0.50) * bucket_ns);
        p99.push(hist_pct(&h, hn, 0.99) * bucket_ns);
    }
    let srt = |v: &mut Vec<f64>| v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    srt(&mut mops);
    srt(&mut p50);
    srt(&mut p99);
    println!(
        "k1b lang=rust variant={} k={} lock={} dist={} max={} universe={} parts={} workers={} reps={} ms={} \
         mops_median={:.2} mops_min={:.2} mops_max={:.2} at_p50_ns={:.0} at_p99_ns={:.0} hit_rate={:.4} \
         hits={} misses={} evictions={} retries={} clock={} tick_ns={:.4} bucket_ns={:.2} oslock={} ok=1",
        VNAMES[variant as usize],
        if variant == V_B { k } else { 0 },
        if os { "os" } else { "spin" },
        dist,
        max,
        uf,
        parts,
        nw,
        reps,
        ms,
        mops[reps / 2],
        mops[0],
        mops[reps - 1],
        p50[reps / 2],
        p99[reps / 2],
        if t_ops > 0 { t_hits as f64 / t_ops as f64 } else { 0.0 },
        t_hits,
        t_misses,
        f.evictions.load(Relaxed),
        t_retries,
        CLOCK_NAME,
        tick_ns,
        bucket_ns,
        OSLOCK_NAME
    );
}
