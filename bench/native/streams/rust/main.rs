// Same five kernels as bench.ren. The default lines iterator uses libc
// memchr, as streams.md's Rust column did. `std` selects safe std splitting
// to expose its cost separately. All other code is safe, std-only.
use std::{hint::black_box, iter};
extern "C" { fn memchr(p: *const u8, c: i32, n: usize) -> *const u8; }
struct Lines<'a> { b: &'a [u8], at: usize }
impl<'a> Iterator for Lines<'a> {
    type Item = &'a [u8];
    fn next(&mut self) -> Option<Self::Item> {
        if self.at >= self.b.len() { return None; }
        let rest = &self.b[self.at..];
        // SAFETY: memchr reads at most rest.len() initialized bytes.
        // Its non-null result points inside that same slice.
        let q = unsafe { memchr(rest.as_ptr(), 10, rest.len()) };
        let len = if q.is_null() { rest.len() } else { q as usize - rest.as_ptr() as usize };
        let line = &rest[..len];
        self.at += len + 1;
        Some(line)
    }
}
fn random(s: &mut i64) -> i64 { *s = *s * 48271 % 2147483647; *s }
fn log_input(n: usize) -> Vec<u8> {
    let mut b = Vec::with_capacity(n * 73); let mut s = 42;
    for _ in 0..n {
        let x = random(&mut s); let mut id = random(&mut s) % 1_000_000_000;
        let len = 20 + random(&mut s) % 40;
        b.push(if x % 20 == 0 { b'E' } else { b'I' }); b.push(b' ');
        for _ in 0..9 { b.push(b'0' + (id % 10) as u8); id /= 10; }
        b.push(b' ');
        for j in 0..len { b.push(b'a' + ((x + j) % 26) as u8); }
        b.push(10);
    }
    b
}
fn parse(b: &[u8]) -> (bool, i64) {
    let mut id = 0; for c in &b[2..11] { id = id * 10 + (c - b'0') as i64; }
    (b[0] == b'E', id)
}
fn total(rows: impl Iterator<Item=i64>) -> i64 { rows.map(|x| x + 1).sum() }
fn logs(s: &str, take: usize, salt: i64, std_lines: bool) -> i64 {
    if std_lines {
        total(s.split_terminator('\n').map(str::as_bytes).map(parse)
            .filter(|e| e.0).take(take).map(|e| e.1 ^ salt))
    } else {
        total(Lines { b: s.as_bytes(), at: 0 }.map(parse).filter(|e| e.0).take(take).map(|e| e.1 ^ salt))
    }
}
struct Tree { value: i64, kids: Vec<Tree> }
fn tree_input(lo: usize, hi: usize) -> Option<Tree> {
    if lo >= hi { return None; } let mid = (lo + hi) / 2;
    let kids = vec![tree_input(lo, mid), tree_input(mid + 1, hi)].into_iter().flatten().collect();
    Some(Tree { value: (mid as i64 * 48271 + 7) % 2147483647, kids })
}
struct Walk<'a> { first: Option<&'a Tree>, stack: Vec<std::slice::Iter<'a, Tree>> }
impl<'a> Iterator for Walk<'a> {
    type Item = i64;
    fn next(&mut self) -> Option<i64> {
        if let Some(t) = self.first.take() { self.stack.push(t.kids.iter()); return Some(t.value); }
        loop { match self.stack.last_mut()?.next() {
            Some(t) => { self.stack.push(t.kids.iter()); return Some(t.value); }
            None => { self.stack.pop(); }
        }}
    }
}
fn boxed(t: &Tree) -> Box<dyn Iterator<Item=i64> + '_> {
    Box::new(iter::once(t.value).chain(t.kids.iter().flat_map(boxed)))
}
struct Dedup<I> { src: I, last: Option<i64> }
impl<I: Iterator<Item=i64>> Iterator for Dedup<I> {
    type Item = i64;
    fn next(&mut self) -> Option<i64> {
        loop { let x = self.src.next()?;
            if self.last != Some(x) { self.last = Some(x); return Some(x); }
        }
    }
}
fn deltas_input(n: usize) -> Vec<i64> { let mut s = 99; (0..n).map(|_| (random(&mut s) % 16 == 0) as i64).collect() }
fn zip_input(n: usize) -> Vec<i64> { let mut s = 5; (0..n).map(|_| { let x = random(&mut s); if x % 8 == 0 { -1 - x/8 } else { x/8 } }).collect() }
fn main() {
    let a: Vec<_> = std::env::args().collect();
    let n = a.get(1).map(|x| x.parse().unwrap()).unwrap_or(1_000_000);
    let rounds: i64 = a.get(2).map(|x| x.parse().unwrap()).unwrap_or(20);
    assert!(n >= 25, "size must be at least 25");
    assert!(rounds > 0, "rounds must be positive");
    let variant = a.get(3).map(|s| s.as_str()).unwrap_or("libc");
    let which = a.get(4).map(|s| s.as_str()).unwrap_or("all");
    // Kernel selector avoids charging unrelated input generation to a kernel.
    for w in ["w1", "w2", "w3", "w4", "w5"] {
        if which != "all" && which != w { continue; }
        let b = if w == "w1" || w == "w5" { String::from_utf8(log_input(n)).unwrap() } else { String::new() };
        let t = if w == "w2" { tree_input(0, n) } else { None };
        let ds = if w == "w3" { deltas_input(n) } else { Vec::new() };
        let xs = if w == "w4" { zip_input(n) } else { Vec::new() };
        let mut sum = 0;
        for r in 0..rounds {
            let salt = black_box(r);
            sum += match w {
                "w1" => logs(black_box(&b), n / 25, black_box(r), variant == "std"),
                "w5" => logs(black_box(&b), usize::MAX, black_box(r), variant == "std"),
                "w2" => { let root = black_box(t.as_ref().unwrap());
                    if variant == "boxed" { boxed(root).filter(|x| x%7 == 0).take(n/8).map(|x| x ^ r).sum() }
                    else { Walk { first: Some(root), stack: Vec::new() }.filter(|x| x%7 == 0).take(n/8).map(|x| x ^ r).sum() }
                },
                "w3" => { let src = black_box(&ds).iter().scan(black_box(r), |v, d| { *v += d; Some(*v / 2) }); Dedup { src, last: None }.sum() },
                "w4" => (0..(n as i64*21/16)).filter(|a| a%3 != 0).zip(black_box(&xs).iter().filter(|b| **b >= 0)).map(|(a,b)| a ^ b ^ salt).sum(),
                _ => unreachable!()
            };
        }
        println!("{}", black_box(sum));
    }
}
