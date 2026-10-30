// cache3, Rust: the same three Ren variants as ../c/cache3.c, with
// parking_lot locks (barging with eventual fairness, closest to decision 10's
// "fair, not first in first out"), plus dashmap and moka as baselines.
// Same workload generator and value checks as the C, so checksums agree.
use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use parking_lot::{Condvar, Mutex};

// ------------------------------------------------------------ platform
#[repr(C)]
struct Timebase { numer: u32, denom: u32 }
extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut Timebase) -> i32;
    fn pthread_set_qos_class_self_np(qos: u32, rel: i32) -> i32;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
static mut TB: (u64, u64) = (1, 1);
#[inline] fn now_ticks() -> u64 { unsafe { mach_absolute_time() } }
#[inline] fn ticks_ns(t: u64) -> u64 { unsafe { t * TB.0 / TB.1 } }

// ------------------------------------------------------------ config
#[derive(Clone)]
struct Cfg {
    variant: String, workers: usize, ops: u64, reps: usize, keys: u64, cap: u64, zipf: f64,
    write_pct: u64, fetch_us: u64, spin: bool, stripes: usize, parts: usize, seed: u64, qos: bool, verbose: bool,
}

// ------------------------------------------------------------ utils
#[inline] fn mix64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}
#[inline] fn splitmix(s: &mut u64) -> u64 {
    *s = s.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *s;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}
#[derive(Default, Clone, Copy)]
struct MixHasher(u64);
impl Hasher for MixHasher {
    fn finish(&self) -> u64 { mix64(self.0) }
    fn write(&mut self, b: &[u8]) { for x in b { self.0 = (self.0 << 8) ^ *x as u64; } }
    fn write_u64(&mut self, v: u64) { self.0 = v; }
}
#[derive(Default, Clone, Copy)]
struct BuildMix;
impl BuildHasher for BuildMix { type Hasher = MixHasher; fn build_hasher(&self) -> MixHasher { MixHasher(0) } }

// ------------------------------------------------------------ values
#[derive(Clone, Copy, Default)]
struct Val { key: u64, check: u64, stamp: u64, stamp_chk: u64 }
#[inline] fn check_of(k: u64) -> u64 { mix64(k ^ 0x5eed) }
#[inline] fn stamp_chk_of(k: u64, s: u64) -> u64 { mix64(s ^ (k << 1)) }
fn fresh(k: u64) -> Val { Val { key: k, check: check_of(k), stamp: 0, stamp_chk: stamp_chk_of(k, 0) } }

#[derive(Default, Clone)]
struct Ctr { reads: u64, writes: u64, hits: u64, misses: u64, fetches: u64, dup_fills: u64, coalesced: u64,
             evictions: u64, bad: u64, fetch_ticks: u64, checksum: u64, stamp_seq: u64 }

fn fetch(cfg: &Cfg, k: u64, c: &mut Ctr) -> Val {
    let t0 = now_ticks();
    if cfg.fetch_us > 0 {
        if cfg.spin {
            let end = ticks_ns(t0) + cfg.fetch_us * 1000;
            while ticks_ns(now_ticks()) < end { std::hint::spin_loop(); }
        } else {
            std::thread::sleep(std::time::Duration::from_micros(cfg.fetch_us));
        }
    }
    c.fetches += 1;
    c.fetch_ticks += now_ticks() - t0;
    fresh(k)
}
#[inline] fn apply_write(v: &mut Val, k: u64, c: &mut Ctr) {
    c.stamp_seq += 1; v.stamp = c.stamp_seq; v.stamp_chk = stamp_chk_of(k, c.stamp_seq);
}
#[inline] fn observe(v: &Val, k: u64, wr: bool, c: &mut Ctr) {
    if v.key != k || v.check != check_of(k) || v.stamp_chk != stamp_chk_of(k, v.stamp) { c.bad += 1; }
    if !wr { c.checksum = c.checksum.wrapping_add(v.check); }
}

// ------------------------------------------------------------ exact LRU map (slab + index links)
const NIL: u32 = u32::MAX;
struct Node<V> { key: u64, val: V, prev: u32, next: u32 }
struct Lru<V> { map: HashMap<u64, u32, BuildMix>, nodes: Vec<Node<V>>, free: Vec<u32>, head: u32, tail: u32, cap: usize }
impl<V> Lru<V> {
    fn new(cap: usize) -> Self {
        Lru { map: HashMap::with_capacity_and_hasher(cap * 2, BuildMix), nodes: Vec::with_capacity(cap + 64),
              free: Vec::new(), head: NIL, tail: NIL, cap }
    }
    fn len(&self) -> usize { self.map.len() }
    #[inline] fn find(&self, k: u64) -> Option<u32> { self.map.get(&k).copied() }
    fn unlink(&mut self, i: u32) {
        let (p, n) = (self.nodes[i as usize].prev, self.nodes[i as usize].next);
        if p != NIL { self.nodes[p as usize].next = n } else { self.head = n }
        if n != NIL { self.nodes[n as usize].prev = p } else { self.tail = p }
    }
    fn push_front(&mut self, i: u32) {
        self.nodes[i as usize].prev = NIL; self.nodes[i as usize].next = self.head;
        if self.head != NIL { self.nodes[self.head as usize].prev = i } else { self.tail = i }
        self.head = i;
    }
    #[inline] fn touch(&mut self, i: u32) { if self.head != i { self.unlink(i); self.push_front(i); } }
    fn insert(&mut self, k: u64, v: V) -> u32 {
        let node = Node { key: k, val: v, prev: NIL, next: NIL };
        let i = if let Some(i) = self.free.pop() { self.nodes[i as usize] = node; i }
                else { self.nodes.push(node); (self.nodes.len() - 1) as u32 };
        self.map.insert(k, i); self.push_front(i); i
    }
    fn remove(&mut self, i: u32) { self.unlink(i); let k = self.nodes[i as usize].key; self.map.remove(&k); self.free.push(i); }
}

// ------------------------------------------------------------ handler (one / striped)
#[repr(align(128))]
struct Inst { m: Mutex<Lru<Val>> }

// ------------------------------------------------------------ actors
struct Actor { lock: Mutex<Val>, ready: AtomicBool }
#[derive(Clone, Copy)]
struct Slot { a: *mut Actor, pins: u32 }
unsafe impl Send for Slot {}
#[repr(align(128))]
struct Part { m: Mutex<Lru<Slot>>, setup_mu: Mutex<()>, setup_cv: Condvar }

enum Cache {
    Handler { insts: Vec<Inst>, hold: bool },
    Actors { parts: Vec<Part> },
    Dash(dashmap::DashMap<u64, Val, BuildMix>),
    Moka(moka::sync::Cache<u64, Val, BuildMix>),
}
#[inline] fn route(k: u64, n: usize) -> usize { if n == 1 { 0 } else { ((mix64(k ^ 0xabcd) >> 32) % n as u64) as usize } }

impl Cache {
    fn new(cfg: &Cfg) -> Cache {
        let cap = cfg.cap as usize;
        match cfg.variant.as_str() {
            "one" | "one_hold" | "striped" | "striped_hold" => {
                let n = if cfg.variant.starts_with("one") { 1 } else { cfg.stripes };
                Cache::Handler { insts: (0..n).map(|_| Inst { m: Mutex::new(Lru::new((cap / n).max(1))) }).collect(),
                                 hold: cfg.variant.ends_with("hold") }
            }
            "actors" => Cache::Actors { parts: (0..cfg.parts).map(|_| Part { m: Mutex::new(Lru::new((cap / cfg.parts).max(1))),
                                         setup_mu: Mutex::new(()), setup_cv: Condvar::new() }).collect() },
            "dashmap" => Cache::Dash(dashmap::DashMap::with_hasher(BuildMix)),
            "moka" => Cache::Moka(moka::sync::Cache::builder().max_capacity(cfg.cap).build_with_hasher(BuildMix)),
            v => { eprintln!("unknown variant {v}"); std::process::exit(2) }
        }
    }
    fn prefill(&self, k: u64) {
        match self {
            Cache::Handler { insts, .. } => {
                let mut m = insts[route(k, insts.len())].m.lock();
                if m.find(k).is_none() {
                    if m.len() >= m.cap { let t = m.tail; m.remove(t); }
                    m.insert(k, fresh(k));
                }
            }
            Cache::Actors { parts } => {
                let mut m = parts[route(k, parts.len())].m.lock();
                if m.find(k).is_none() && m.len() < m.cap {
                    let a = Box::into_raw(Box::new(Actor { lock: Mutex::new(fresh(k)), ready: AtomicBool::new(true) }));
                    m.insert(k, Slot { a, pins: 0 });
                }
            }
            Cache::Dash(d) => { d.insert(k, fresh(k)); }
            Cache::Moka(m) => { m.insert(k, fresh(k)); }
        }
    }
    fn resident(&self) -> u64 {
        match self {
            Cache::Handler { insts, .. } => insts.iter().map(|i| i.m.lock().len() as u64).sum(),
            Cache::Actors { parts } => parts.iter().map(|p| p.m.lock().len() as u64).sum(),
            Cache::Dash(d) => d.len() as u64,
            Cache::Moka(m) => { m.run_pending_tasks(); m.entry_count() }
        }
    }

    fn op(&self, cfg: &Cfg, k: u64, wr: bool, c: &mut Ctr) {
        let out: Val;
        match self {
            Cache::Handler { insts, hold } => {
                let inst = &insts[route(k, insts.len())];
                let mut m = inst.m.lock();
                let i = match m.find(k) {
                    Some(i) => { c.hits += 1; m.touch(i); i }
                    None => {
                        c.misses += 1;
                        let v = if *hold { fetch(cfg, k, c) }            // held across the call
                                else { let v = parking_lot::MutexGuard::unlocked(&mut m, || fetch(cfg, k, c)); v }; // release
                        match m.find(k) {
                            Some(i) => { c.dup_fills += 1; m.touch(i); i }
                            None => {
                                if m.len() >= m.cap { let t = m.tail; m.remove(t); c.evictions += 1; }
                                m.insert(k, v)
                            }
                        }
                    }
                };
                let v = &mut m.nodes[i as usize].val;
                if wr { apply_write(v, k, c); }
                out = *v;
            }
            Cache::Actors { parts } => {
                let p = &parts[route(k, parts.len())];
                let (a, idx) = actors_at(cfg, p, k, c);
                {
                    let actor = unsafe { &*a };
                    let mut v = actor.lock.lock();       // one operation, one call
                    if wr { apply_write(&mut v, k, c); }
                    out = *v;
                }
                let mut m = p.m.lock();                  // leaving at(): unpin, most recently released
                m.nodes[idx as usize].val.pins -= 1;
                m.touch(idx);
            }
            Cache::Dash(d) => {
                if wr {
                    if let Some(mut e) = d.get_mut(&k) { c.hits += 1; apply_write(&mut e, k, c); out = *e; }
                    else {
                        c.misses += 1;
                        let v = fetch(cfg, k, c);
                        let mut fresh_insert = true;
                        let mut e = d.entry(k).and_modify(|_| fresh_insert = false).or_insert(v);
                        if !fresh_insert { c.dup_fills += 1; }
                        apply_write(&mut e, k, c); out = *e;
                    }
                } else if let Some(e) = d.get(&k) { c.hits += 1; out = *e; }
                else {
                    c.misses += 1;
                    let v = fetch(cfg, k, c);
                    let mut fresh_insert = true;
                    let e = d.entry(k).and_modify(|_| fresh_insert = false).or_insert(v);
                    if !fresh_insert { c.dup_fills += 1; }
                    out = *e;
                }
            }
            Cache::Moka(m) => {
                let mut missed = false;
                let mut v = m.get_with(k, || { missed = true; fetch(cfg, k, c) });
                if missed { c.misses += 1 } else { c.hits += 1 }   // waiters on another's init count as hits
                if wr { apply_write(&mut v, k, c); m.insert(k, v); }
                out = v;
            }
        }
        observe(&out, k, wr, c);
    }
}

// Docs.at(k): find or make k's actor, pinned. Returns the actor and its slot.
fn actors_at(cfg: &Cfg, p: &Part, k: u64, c: &mut Ctr) -> (*mut Actor, u32) {
    let mut victims: Vec<*mut Actor> = Vec::new();
    loop {
        let mut m = p.m.lock();
        if let Some(i) = m.find(k) {
            m.nodes[i as usize].val.pins += 1;
            let a = m.nodes[i as usize].val.a;
            drop(m);
            let actor = unsafe { &*a };
            if actor.ready.load(Ordering::Acquire) { c.hits += 1 } else {
                c.coalesced += 1;
                let mut g = p.setup_mu.lock();
                while !actor.ready.load(Ordering::Acquire) { p.setup_cv.wait(&mut g); }
            }
            return (a, i);
        }
        let mut stuck = false;
        while m.len() >= m.cap {
            let mut t = m.tail;
            while t != NIL && m.nodes[t as usize].val.pins > 0 { t = m.nodes[t as usize].prev; }
            if t == NIL { stuck = true; break; }
            victims.push(m.nodes[t as usize].val.a); m.remove(t); c.evictions += 1;
        }
        if stuck { drop(m); std::thread::yield_now(); continue; }
        c.misses += 1;
        let a = Box::into_raw(Box::new(Actor { lock: Mutex::new(Val::default()), ready: AtomicBool::new(false) }));
        let i = m.insert(k, Slot { a, pins: 1 });
        drop(m);
        for v in victims.drain(..) { unsafe { drop(Box::from_raw(v)) } }   // finally, on the caller's task
        let v = fetch(cfg, k, c);                                           // setup fetches
        {
            let _g = p.setup_mu.lock();
            *unsafe { &*a }.lock.lock() = v;
            unsafe { &*a }.ready.store(true, Ordering::Release);
            p.setup_cv.notify_all();
        }
        return (a, i);
    }
}
impl Drop for Cache {
    fn drop(&mut self) {
        if let Cache::Actors { parts } = self {
            for p in parts.iter() {
                let m = p.m.lock();
                for (_, &i) in m.map.iter() { unsafe { drop(Box::from_raw(m.nodes[i as usize].val.a)) } }
            }
        }
    }
}
unsafe impl Sync for Cache {}

// ------------------------------------------------------------ histogram (same buckets as the C)
const HB: usize = 128 + 64 * 48;
#[inline] fn hbucket(v: u64) -> usize {
    if v < 128 { return v as usize }
    let e = 63 - v.leading_zeros() as u64;
    128 + ((e - 7) * 64) as usize + ((v >> (e - 6)) & 63) as usize
}
fn hvalue(b: usize) -> u64 { if b < 128 { b as u64 } else { let e = (b - 128) / 64 + 7; let s = (b - 128) % 64; ((64 + s) as u64) << (e - 6) } }
fn hpct(h: &[u64], total: u64, q: f64) -> u64 {
    let want = ((q * total as f64).ceil() as u64).max(1);
    let mut acc = 0;
    for (b, n) in h.iter().enumerate() { acc += n; if acc >= want { return hvalue(b) } }
    hvalue(HB - 1)
}

fn arg(args: &[String], name: &str) -> Option<String> { args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned()) }

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let g = |n: &str, d: &str| arg(&args, n).unwrap_or_else(|| d.to_string());
    let cfg = Cfg {
        variant: g("--variant", "striped"), workers: g("--workers", "4").parse().unwrap(), ops: g("--ops", "200000").parse().unwrap(),
        reps: g("--reps", "1").parse().unwrap(), keys: g("--keys", "20000").parse().unwrap(), cap: g("--cap", "16000").parse().unwrap(),
        zipf: g("--zipf", "1.1").parse().unwrap(), write_pct: g("--write-pct", "5").parse().unwrap(),
        fetch_us: g("--fetch-us", "50").parse().unwrap(), spin: g("--fetch", "spin") != "sleep",
        stripes: g("--stripes", "16").parse().unwrap(), parts: g("--parts", "16").parse().unwrap(),
        seed: g("--seed", "42").parse().unwrap(), qos: g("--qos", "1") != "0", verbose: args.iter().any(|a| a == "-v"),
    };
    unsafe { let mut tb = Timebase { numer: 0, denom: 0 }; mach_timebase_info(&mut tb); TB = (tb.numer as u64, tb.denom as u64); }

    // workload, identical to the C
    let mut cdf = vec![0f64; cfg.keys as usize];
    let mut t = 0f64;
    for i in 0..cfg.keys as usize { t += 1.0 / ((i + 1) as f64).powf(cfg.zipf); cdf[i] = t; }
    for x in cdf.iter_mut() { *x /= t; }
    let streams: Vec<Vec<u32>> = (0..cfg.workers).map(|w| {
        let mut s = cfg.seed ^ ((w as u64 + 1).wrapping_mul(0x9e3779b97f4a7c15));
        (0..cfg.ops).map(|_| {
            let u = (splitmix(&mut s) >> 11) as f64 * (1.0 / (1u64 << 53) as f64);
            let (mut lo, mut hi) = (0usize, cfg.keys as usize - 1);
            while lo < hi { let mid = (lo + hi) / 2; if cdf[mid] > u { hi = mid } else { lo = mid + 1 } }
            let wr = splitmix(&mut s) % 100 < cfg.write_pct;
            lo as u32 | ((wr as u32) << 31)
        }).collect()
    }).collect();

    let vname = match cfg.variant.as_str() {
        "actors" => format!("actors_p{}", cfg.parts),
        "striped" | "striped_hold" => format!("{}{}", cfg.variant, cfg.stripes),
        v => v.to_string(),
    };
    let (mut mops, mut p50, mut p99, mut p999, mut h99) = (vec![], vec![], vec![], vec![], vec![]);
    let mut ok = true; let mut checksum0 = 0; let mut last = Ctr::default(); let mut resident = 0;
    for r in 0..cfg.reps {
        let cache = Cache::new(&cfg);
        for k in 0..cfg.cap.min(cfg.keys) { cache.prefill(k); }
        let prefilled = cache.resident();
        let ready = AtomicUsize::new(0); let go = AtomicBool::new(false);
        let mut t0 = 0;
        let results: Vec<(Ctr, Vec<u64>, Vec<u64>, u64)> = std::thread::scope(|sc| {
            let hs: Vec<_> = (0..cfg.workers).map(|w| {
                let (cache, cfg, st, ready, go) = (&cache, &cfg, &streams[w], &ready, &go);
                sc.spawn(move || {
                    if cfg.qos { unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); } }
                    let mut c = Ctr { stamp_seq: (w as u64) << 40, ..Default::default() };
                    let mut h = vec![0u64; HB]; let mut hh = vec![0u64; HB];
                    ready.fetch_add(1, Ordering::SeqCst);
                    while !go.load(Ordering::Acquire) { std::hint::spin_loop(); }
                    let mut prev = now_ticks();
                    for &op in st.iter() {
                        let k = (op & 0x7fff_ffff) as u64; let wr = op >> 31 != 0;
                        if wr { c.writes += 1 } else { c.reads += 1 }
                        let h0 = c.hits;
                        cache.op(cfg, k, wr, &mut c);
                        let t = now_ticks();
                        let b = hbucket(ticks_ns(t - prev));
                        h[b] += 1; if c.hits != h0 { hh[b] += 1; }
                        prev = t;
                    }
                    (c, h, hh, prev)
                })
            }).collect();
            while ready.load(Ordering::SeqCst) < cfg.workers { std::thread::yield_now(); }
            t0 = now_ticks();
            go.store(true, Ordering::Release);
            hs.into_iter().map(|h| h.join().unwrap()).collect()
        });
        let tend = results.iter().map(|r| r.3).max().unwrap();
        let secs = ticks_ns(tend - t0) as f64 / 1e9;
        let mut s = Ctr::default(); let mut hall = vec![0u64; HB]; let mut hhit = vec![0u64; HB];
        for (c, h, hh, _) in &results {
            s.reads += c.reads; s.writes += c.writes; s.hits += c.hits; s.misses += c.misses; s.fetches += c.fetches;
            s.dup_fills += c.dup_fills; s.coalesced += c.coalesced; s.evictions += c.evictions; s.bad += c.bad;
            s.fetch_ticks += c.fetch_ticks; s.checksum = s.checksum.wrapping_add(c.checksum);
            for b in 0..HB { hall[b] += h[b]; hhit[b] += hh[b]; }
        }
        let total = s.reads + s.writes;
        resident = cache.resident();
        let mut rok = s.bad == 0 && total == cfg.workers as u64 * cfg.ops && s.hits + s.misses + s.coalesced == total
            && s.fetches == s.misses;
        match &cache {
            Cache::Handler { .. } => rok &= prefilled + s.misses - s.dup_fills - s.evictions == resident && resident <= cfg.cap,
            Cache::Actors { .. } => rok &= prefilled + s.misses - s.evictions == resident && resident <= cfg.cap,
            Cache::Dash(_) => rok &= prefilled + s.misses - s.dup_fills == resident,
            Cache::Moka(_) => rok &= resident <= cfg.cap,
        }
        if r == 0 { checksum0 = s.checksum } else if s.checksum != checksum0 { rok = false }
        ok &= rok;
        mops.push(total as f64 / secs / 1e6);
        p50.push(hpct(&hall, total, 0.5) as f64); p99.push(hpct(&hall, total, 0.99) as f64);
        p999.push(hpct(&hall, total, 0.999) as f64); h99.push(hpct(&hhit, s.hits, 0.99) as f64);
        if cfg.verbose {
            eprintln!("rep {r}: {:.3} Mops/s hits={} misses={} coalesced={} dup={} evict={} resident={} bad={} ok={}",
                      mops[r], s.hits, s.misses, s.coalesced, s.dup_fills, s.evictions, resident, s.bad, rok);
        }
        last = s;
    }
    let med = |v: &mut Vec<f64>| { v.sort_by(|a, b| a.partial_cmp(b).unwrap()); v[v.len() / 2] };
    let (mmed, mmin, mmax) = { let m = med(&mut mops); (m, mops[0], mops[mops.len() - 1]) };
    let total = last.reads + last.writes;
    println!("impl=rust variant={} workers={} reps={} ops={} mops_median={:.4} mops_min={:.4} mops_max={:.4} p50_ns={:.0} p99_ns={:.0} p999_ns={:.0} p99_hit_ns={:.0} hit_pct={:.3} misses={} fetches={} coalesced={} dup_fills={} evictions={} resident={} fetch_avg_us={:.1} checksum={:016x} ok={}",
             vname, cfg.workers, cfg.reps, total, mmed, mmin, mmax, med(&mut p50), med(&mut p99), med(&mut p999), med(&mut h99),
             100.0 * last.hits as f64 / total as f64, last.misses, last.fetches, last.coalesced, last.dup_fills, last.evictions, resident,
             if last.fetches > 0 { ticks_ns(last.fetch_ticks) as f64 / last.fetches as f64 / 1000.0 } else { 0.0 },
             last.checksum, ok as u8);
    std::process::exit(if ok { 0 } else { 1 });
}
