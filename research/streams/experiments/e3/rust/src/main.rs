// E3's Rust twins: std only, no unsafe, one thread. Each workload is
// written the way a good Rust programmer writes it: iterator adapters,
// a user adapter as a struct implementing Iterator, a recursive walk
// both as an explicit-stack iterator and as boxed `dyn` chains, and the
// push form as a recursive function over `FnMut -> ControlFlow`.
use std::iter;
use std::ops::ControlFlow;
use std::hint::black_box;
use std::time::Instant;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

// ---------------- W1 and W5 ----------------
fn make_log(target: usize) -> Vec<u8> {
    let mut b = Vec::with_capacity(target + 256);
    let mut r = Rng(42);
    let lv = ["DEBUG", "INFO", "WARN", "ERROR"];
    let sv = ["api", "db", "auth", "cache"];
    while b.len() < target {
        let x = r.next();
        let (sec, ms, p) = (x % 60, (x >> 8) % 1000, (x >> 20) % 100);
        let l = if p < 30 { lv[0] } else if p < 80 { lv[1] } else if p < 95 { lv[2] } else { lv[3] };
        let s = sv[((x >> 27) % 4) as usize];
        let id = r.next() % 1000000000;
        let mlen = 20 + r.next() % 60;
        b.extend_from_slice(b"2026-10-29T11:43:");
        b.push(b'0' + (sec / 10) as u8);
        b.push(b'0' + (sec % 10) as u8);
        b.push(b'.');
        b.push(b'0' + (ms / 100) as u8);
        b.push(b'0' + (ms / 10 % 10) as u8);
        b.push(b'0' + (ms % 10) as u8);
        b.extend_from_slice(b"Z ");
        b.extend_from_slice(l.as_bytes());
        b.push(b' ');
        b.extend_from_slice(b"svc=");
        b.extend_from_slice(s.as_bytes());
        b.extend_from_slice(b" id=");
        b.extend_from_slice(id.to_string().as_bytes());
        b.extend_from_slice(b" msg=");
        for _ in 0..mlen {
            b.push(b'a' + (r.next() % 26) as u8);
        }
        b.push(b'\n');
    }
    b
}

const DEBUG: i64 = 0;
const INFO: i64 = 1;
const WARN: i64 = 2;
const ERROR: i64 = 3;
const BAD: i64 = -1;

#[derive(Clone, Copy)]
struct Entry {
    level: i64,
    id: i64,
}

#[inline]
fn parse(s: &str) -> Entry {
    let p = s.as_bytes();
    let n = p.len();
    let mut i = 25;
    let mut e = Entry { level: BAD, id: 0 };
    if n <= i {
        return e;
    }
    e.level = match p[i] {
        b'D' => DEBUG,
        b'I' => INFO,
        b'W' => WARN,
        b'E' => ERROR,
        _ => return e,
    };
    while i < n && p[i] != b' ' {
        i += 1;
    }
    i += 1;
    while i < n && p[i] != b' ' {
        i += 1;
    }
    i += 4;
    let mut id = 0i64;
    while i < n && p[i].is_ascii_digit() {
        id = id * 10 + (p[i] - b'0') as i64;
        i += 1;
    }
    e.id = id;
    e
}

const W1_TAKE: usize = 40000;

#[inline(never)]
fn w1_iter(s: &str) -> (i64, i64) {
    s.split_terminator('\n')
        .map(parse)
        .filter(|e| e.level == ERROR)
        .take(W1_TAKE)
        .fold((0, 0), |(n, ids), e| (n + 1, ids + e.id))
}

#[inline(never)]
fn w1_for(s: &str) -> (i64, i64) {
    let (mut n, mut ids) = (0, 0);
    for e in s
        .split_terminator('\n')
        .map(parse)
        .filter(|e| e.level == ERROR)
        .take(W1_TAKE)
    {
        n += 1;
        ids += e.id;
    }
    (n, ids)
}

fn total(rows: impl Iterator<Item = Entry>) -> (i64, i64) {
    let (mut n, mut ids) = (0, 0);
    for e in rows {
        n += 1;
        ids += e.id;
    }
    (n, ids)
}
#[inline(never)]
fn total_dyn(rows: &mut dyn Iterator<Item = Entry>) -> (i64, i64) {
    let (mut n, mut ids) = (0, 0);
    for e in rows {
        n += 1;
        ids += e.id;
    }
    (n, ids)
}

#[inline(never)]
fn w5_inline(s: &str) -> (i64, i64) {
    let (mut n, mut ids) = (0, 0);
    for e in s.split_terminator('\n').map(parse).filter(|e| e.level == ERROR) {
        n += 1;
        ids += e.id;
    }
    (n, ids)
}
#[inline(never)]
fn w5_generic(s: &str) -> (i64, i64) {
    total(s.split_terminator('\n').map(parse).filter(|e| e.level == ERROR))
}
#[inline(never)]
fn w5_dyn(s: &str) -> (i64, i64) {
    let mut it = s.split_terminator('\n').map(parse).filter(|e| e.level == ERROR);
    total_dyn(&mut it)
}

// ---------------- W2 ----------------
struct Tree {
    val: i64,
    kids: Vec<Tree>,
}

fn build(r: &mut Rng, d: i32) -> Tree {
    let val = r.next() as i64;
    let n = if d >= 20 { 0 } else if d % 5 == 2 { 3 } else { 2 };
    let mut kids = Vec::with_capacity(n);
    for _ in 0..n {
        kids.push(build(r, d + 1));
    }
    Tree { val, kids }
}

const W2_TAKE: usize = 1300000;

// the usual iterator: an explicit stack of children's iterators
struct Walk<'a> {
    first: Option<&'a Tree>,
    stack: Vec<std::slice::Iter<'a, Tree>>,
}
impl<'a> Iterator for Walk<'a> {
    type Item = i64;
    #[inline]
    fn next(&mut self) -> Option<i64> {
        if let Some(t) = self.first.take() {
            self.stack.push(t.kids.iter());
            return Some(t.val);
        }
        loop {
            let top = self.stack.last_mut()?;
            match top.next() {
                Some(t) => {
                    self.stack.push(t.kids.iter());
                    return Some(t.val);
                }
                None => {
                    self.stack.pop();
                }
            }
        }
    }
}
#[inline(never)]
fn w2_stack(t: &Tree) -> i64 {
    Walk { first: Some(t), stack: Vec::new() }
        .filter(|v| v % 7 == 0)
        .take(W2_TAKE)
        .sum()
}

// the recursive one-liner: boxed chains, O(depth) per item
fn walk_boxed(t: &Tree) -> Box<dyn Iterator<Item = i64> + '_> {
    Box::new(iter::once(t.val).chain(t.kids.iter().flat_map(walk_boxed)))
}
#[inline(never)]
fn w2_boxed(t: &Tree) -> i64 {
    walk_boxed(t).filter(|v| v % 7 == 0).take(W2_TAKE).sum()
}

// push: internal iteration
fn walk_push(t: &Tree, f: &mut impl FnMut(i64) -> ControlFlow<()>) -> ControlFlow<()> {
    f(t.val)?;
    for c in &t.kids {
        walk_push(c, f)?;
    }
    ControlFlow::Continue(())
}
#[inline(never)]
fn w2_push(t: &Tree) -> i64 {
    let (mut left, mut sum) = (W2_TAKE, 0i64);
    let _ = walk_push(t, &mut |v| {
        if v % 7 != 0 {
            return ControlFlow::Continue(());
        }
        sum += v;
        left -= 1;
        if left == 0 { ControlFlow::Break(()) } else { ControlFlow::Continue(()) }
    });
    sum
}

// ---------------- W3 ----------------
struct DedupBy<I, F, K> {
    src: I,
    key: F,
    last: Option<K>,
}
impl<I: Iterator, K: PartialEq, F: FnMut(&I::Item) -> K> Iterator for DedupBy<I, F, K> {
    type Item = I::Item;
    #[inline]
    fn next(&mut self) -> Option<I::Item> {
        loop {
            let x = self.src.next()?;
            let k = (self.key)(&x);
            if self.last.as_ref() != Some(&k) {
                self.last = Some(k);
                return Some(x);
            }
        }
    }
}
fn dedup_by<I: Iterator, K, F: FnMut(&I::Item) -> K>(src: I, key: F) -> DedupBy<I, F, K> {
    DedupBy { src, key, last: None }
}
#[inline(never)]
fn w3_iter(ds: &[i64]) -> i64 {
    let ticks = ds.iter().scan(0i64, |v, d| {
        *v += d;
        Some(*v)
    });
    dedup_by(ticks.map(|x| x / 2), |x| *x).sum()
}

// ---------------- W4 ----------------
const NB: usize = 16 << 20;
const NA: i64 = 22020096;
#[inline(never)]
fn w4_zip(bs: &[i64]) -> i64 {
    (0..NA)
        .filter(|i| i % 3 != 0)
        .zip(bs.iter().copied().filter(|&x| x >= 0))
        .map(|(a, b)| a ^ b)
        .sum()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (w, v) = (a[1].as_str(), a[2].as_str());
    match w {
        "w1" | "w5" => {
            let buf = make_log(100 << 20);
            let s = std::str::from_utf8(&buf).unwrap();
            let t0 = Instant::now();
            let (mut n, mut ids) = (0i64, 0i64);
            for _ in 0..5 {
                let (x, y) = match (w, v) {
                    ("w1", "iter") => w1_iter(black_box(s)),
                    ("w1", "for") => w1_for(black_box(s)),
                    ("w5", "inline") => w5_inline(black_box(s)),
                    ("w5", "generic") => w5_generic(black_box(s)),
                    ("w5", "dyn") => w5_dyn(black_box(s)),
                    _ => panic!("variant?"),
                };
                n += black_box(x);
                ids += y;
            }
            let el = t0.elapsed().as_nanos();
            println!("bytes={}", buf.len());
            println!("check={}:{}", n, ids);
            println!("{}_ns={}", w, el);
        }
        "w2" => {
            let mut r = Rng(7);
            let t = build(&mut r, 0);
            let t0 = Instant::now();
            let mut s = 0i64;
            for _ in 0..3 {
                s += match v {
                    "stack" => w2_stack(black_box(&t)),
                    "boxed" => w2_boxed(black_box(&t)),
                    "push" => w2_push(black_box(&t)),
                    _ => panic!("variant?"),
                };
            }
            let el = t0.elapsed().as_nanos();
            println!("check={}", s);
            println!("w2_ns={}", el);
        }
        "w3" => {
            let mut r = Rng(99);
            let ds: Vec<i64> = (0..(16usize << 20)).map(|_| (r.next() % 16 == 0) as i64).collect();
            let t0 = Instant::now();
            let mut s = 0i64;
            for _ in 0..8 {
                s += w3_iter(black_box(&ds));
            }
            let el = t0.elapsed().as_nanos();
            println!("check={}", s);
            println!("w3_ns={}", el);
        }
        "w4" => {
            let mut r = Rng(5);
            let bs: Vec<i64> = (0..NB)
                .map(|_| {
                    let x = r.next();
                    if x % 8 == 0 { -1 - (x >> 3) as i64 } else { (x >> 3) as i64 }
                })
                .collect();
            let t0 = Instant::now();
            let mut s = 0i64;
            for _ in 0..8 {
                s += w4_zip(black_box(&bs));
            }
            let el = t0.elapsed().as_nanos();
            println!("check={}", s);
            println!("w4_ns={}", el);
        }
        _ => panic!("workload?"),
    }
}
