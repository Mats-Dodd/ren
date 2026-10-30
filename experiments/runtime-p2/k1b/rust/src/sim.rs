// K1b's hit-rate simulator, Rust. Mirrors c/sim.c bit for bit: the same trace,
// the same policies, the same structure; measure.sh fails if the lines differ.
//
// (The original rust/src/bin/sim.rs was lost: experiments/.gitignore's `bin/`
// also matched rust/src/bin/, so it was never committed. This is a rewrite
// from c/sim.c, kept outside src/bin/ for that reason.)
mod common;
use common::*;

const P_LRU: usize = 0;
const P_PLRU: usize = 1;
const P_S3: usize = 2;
const P_S5: usize = 3;
const P_S10: usize = 4;
const P_CLOCK: usize = 5;
const NPOL: usize = 6;
const PNAMES: [&str; NPOL] = ["lru", "plru", "s3", "s5", "s10", "clock"];

struct Shard {
    mask: u32,
    count: u32,
    cap: u32,
    keys: Vec<u64>,
    idx: Vec<i32>,
    head: i32,
    tail: i32,
}

struct Cache {
    pol: usize,
    k: u32,
    max: u32,
    parts: u32,
    nalloc: u32,
    key: Vec<u64>,
    stamp: Vec<u64>,
    prev: Vec<i32>,
    next: Vec<i32>,
    s: Vec<Shard>,
    rng: u64,
    hand: u64,
    evictions: u64,
    vh: u64,
}

fn die(m: String) -> ! {
    eprintln!("FAIL: {}", m);
    std::process::exit(1)
}

fn find(p: &Shard, k: u64, h: u64) -> i32 {
    let mut s = h as u32 & p.mask;
    loop {
        if p.keys[s as usize] == k {
            return p.idx[s as usize];
        }
        if p.keys[s as usize] == 0 {
            return -1;
        }
        s = (s + 1) & p.mask;
    }
}
fn insert(p: &mut Shard, k: u64, h: u64, i: i32) {
    let mut s = h as u32 & p.mask;
    while p.keys[s as usize] != 0 {
        s = (s + 1) & p.mask;
    }
    p.keys[s as usize] = k;
    p.idx[s as usize] = i;
    p.count += 1;
    if p.count as u64 * 4 > (p.mask as u64 + 1) * 3 {
        die("shard over 3/4".into())
    }
}
fn delete(p: &mut Shard, k: u64, h: u64) {
    let m = p.mask;
    let mut s = h as u32 & m;
    while p.keys[s as usize] != k {
        if p.keys[s as usize] == 0 {
            die("delete of absent key".into())
        }
        s = (s + 1) & m;
    }
    let mut j = s;
    loop {
        j = (j + 1) & m;
        let x = p.keys[j as usize];
        if x == 0 {
            break;
        }
        let home = mix64(x) as u32 & m;
        if (j.wrapping_sub(home) & m) >= (j.wrapping_sub(s) & m) {
            p.keys[s as usize] = x;
            p.idx[s as usize] = p.idx[j as usize];
            s = j;
        }
    }
    p.keys[s as usize] = 0;
    p.count -= 1;
}

impl Cache {
    fn new(pol: usize, max: u32, parts: u32) -> Cache {
        let k = match pol {
            P_S3 => 3,
            P_S5 => 5,
            P_S10 => 10,
            _ => 0,
        };
        let sz = pow2_at_least((max / parts) * 2 + 256) as usize;
        let s = (0..parts)
            .map(|j| Shard {
                mask: sz as u32 - 1,
                count: 0,
                cap: max / parts + (j < max % parts) as u32,
                keys: vec![0; sz],
                idx: vec![0; sz],
                head: -1,
                tail: -1,
            })
            .collect();
        Cache {
            pol,
            k,
            max,
            parts,
            nalloc: 0,
            key: vec![0; max as usize],
            stamp: vec![0; max as usize],
            prev: vec![-1; max as usize],
            next: vec![-1; max as usize],
            s,
            rng: 0x5eed0000u64 + k as u64 * 0x10000, // worker 0's seed in k1b.c
            hand: 0,
            evictions: 0,
            vh: FNV0,
        }
    }

    fn lru_remove(&mut self, l: usize, i: i32) {
        let (pv, nx) = (self.prev[i as usize], self.next[i as usize]);
        if pv >= 0 { self.next[pv as usize] = nx } else { self.s[l].head = nx }
        if nx >= 0 { self.prev[nx as usize] = pv } else { self.s[l].tail = pv }
        self.prev[i as usize] = -1;
        self.next[i as usize] = -1;
    }
    fn lru_push(&mut self, l: usize, i: i32) {
        let hd = self.s[l].head;
        self.prev[i as usize] = -1;
        self.next[i as usize] = hd;
        if hd >= 0 { self.prev[hd as usize] = i } else { self.s[l].tail = i }
        self.s[l].head = i;
    }
    // The list a slot is on: lru keeps one list (shard 0's); plru one per shard.
    fn list_of(&self, h: u64) -> usize {
        if self.pol == P_LRU { 0 } else { part_of(h, self.parts) as usize }
    }

    fn take_victim(&mut self, home: usize) -> i32 {
        let v: i32;
        if self.pol == P_LRU || self.pol == P_PLRU {
            let l = if self.pol == P_LRU { 0 } else { home };
            v = self.s[l].tail;
            self.lru_remove(l, v);
        } else if self.pol == P_CLOCK {
            loop {
                let s = (self.hand % self.max as u64) as usize;
                self.hand += 1;
                if self.stamp[s] != 0 {
                    self.stamp[s] = 0;
                    continue;
                }
                v = s as i32;
                break;
            }
        } else {
            let mut best = u64::MAX;
            let mut b = -1i32;
            for _ in 0..self.k {
                let s = (((splitmix64(&mut self.rng) >> 32) * self.max as u64) >> 32) as usize;
                if self.stamp[s] < best {
                    best = self.stamp[s];
                    b = s as i32;
                }
            }
            v = b;
        }
        let vk = self.key[v as usize];
        let vh = mix64(vk);
        let q = part_of(vh, self.parts) as usize;
        delete(&mut self.s[q], vk, vh);
        self.evictions += 1;
        self.vh = fnv_add(self.vh, vk);
        v
    }

    // One access at time t. True on a hit.
    fn access(&mut self, k: u64, t: u64) -> bool {
        let h = mix64(k);
        let p = part_of(h, self.parts) as usize;
        let mut s = find(&self.s[p], k, h);
        let ls = self.pol == P_LRU || self.pol == P_PLRU;
        if s >= 0 {
            if ls {
                let l = self.list_of(h);
                self.lru_remove(l, s);
                self.lru_push(l, s);
            } else {
                self.stamp[s as usize] = if self.pol == P_CLOCK { 1 } else { t };
            }
            return true;
        }
        let full = if self.pol == P_PLRU { self.s[p].count >= self.s[p].cap } else { self.nalloc >= self.max };
        s = if full {
            self.take_victim(p)
        } else {
            self.nalloc += 1;
            (self.nalloc - 1) as i32
        };
        self.key[s as usize] = k;
        insert(&mut self.s[p], k, h, s);
        if ls {
            let l = self.list_of(h);
            self.lru_push(l, s);
        } else {
            self.stamp[s as usize] = if self.pol == P_CLOCK { 1 } else { t };
        }
        false
    }

    fn check(&self) {
        let name = PNAMES[self.pol];
        let n = self.nalloc;
        if n > self.max { die(format!("{} nalloc {} > max", name, n)) }
        for i in 0..n {
            let k = self.key[i as usize];
            let h = mix64(k);
            if k == 0 || find(&self.s[part_of(h, self.parts) as usize], k, h) != i as i32 {
                die(format!("{} slot {} not mapped", name, i))
            }
        }
        let (mut entries, mut listed) = (0u32, 0u32);
        for p in &self.s {
            let e = p.keys.iter().filter(|&&x| x != 0).count() as u32;
            if e != p.count { die(format!("{} shard count", name)) }
            entries += e;
            if self.pol == P_PLRU && p.count > p.cap { die("plru cap".into()) }
            let mut i = p.head;
            while i >= 0 {
                listed += 1;
                i = self.next[i as usize];
            }
        }
        if entries != n { die(format!("{} entries {} != {}", name, entries, n)) }
        if (self.pol == P_LRU || self.pol == P_PLRU) && listed != n {
            die(format!("{} listed {} != {}", name, listed, n))
        }
    }
}

fn main() {
    let (mut max, mut parts, mut warm, mut measure) = (10000u32, 8u32, -1i64, -1i64);
    let (mut uf, mut dist) = ("2".to_string(), "zipf99".to_string());
    for (a, v) in args() {
        match a.as_str() {
            "--dist" => dist = v,
            "--max" => max = v.parse().unwrap(),
            "--universe" => uf = v,
            "--parts" => parts = v.parse().unwrap(),
            "--warm" => warm = v.parse().unwrap(),
            "--measure" => measure = v.parse().unwrap(),
            _ => {
                eprintln!("unknown arg {}", a);
                std::process::exit(2)
            }
        }
    }
    let di = dist_of(&dist);
    let u = universe(&uf, max);
    if warm < 0 {
        warm = if 10 * max as i64 > 4 * u as i64 { 10 * max as i64 } else { 4 * u as i64 };
    }
    if measure < 0 {
        measure = 20 * max as i64;
    }
    let wl = Workload::new(di, u, max);
    let (mut hits, mut ev, mut vh) = ([0u64; NPOL], [0u64; NPOL], [0u64; NPOL]);
    for pol in 0..NPOL {
        let mut c = Cache::new(pol, max, parts);
        let mut seed = 0x1234u64;
        let mut cur = 0u32;
        for t in 0..warm + measure {
            let hit = c.access(wl.next(&mut seed, &mut cur) as u64, t as u64 + 1);
            if t >= warm && hit {
                hits[pol] += 1;
            }
        }
        c.check();
        ev[pol] = c.evictions;
        vh[pol] = c.vh;
    }
    let mut out = format!(
        "k1b_sim lang=rust dist={} max={} universe={} parts={} warm={} measure={}",
        dist, max, uf, parts, warm, measure
    );
    for p in 0..NPOL {
        out += &format!(" hit_{}={:.6}", PNAMES[p], hits[p] as f64 / measure as f64);
    }
    for p in 0..NPOL {
        out += &format!(" hits_{}={}", PNAMES[p], hits[p]);
    }
    for p in 0..NPOL {
        out += &format!(" ev_{}={}", PNAMES[p], ev[p]);
    }
    for p in 0..NPOL {
        out += &format!(" vh_{}={:016x}", PNAMES[p], vh[p]);
    }
    out += " ok=1";
    println!("{}", out);
}
