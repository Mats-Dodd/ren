// Sized storage: a million bytes in a Vec<u8> and a million i32s, each
// changed in place a round at a time, and an FNV-1a hash of the bytes
// at 32 bits. Arithmetic is in i64, as Ren's is, and each store is
// checked to fit, as Ren's are (`try_from(..).unwrap()`).

use std::convert::TryFrom;
use std::env;

fn next(s: i64) -> i64 {
    s.wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407)
}

fn bytes(n: i64) -> Vec<u8> {
    let mut xs = Vec::new();
    let mut s: i64 = 42;
    for _ in 0..n {
        s = next(s);
        xs.push(u8::try_from((s / 4294967296) & 255).unwrap());
    }
    xs
}

fn ints(n: i64) -> Vec<i32> {
    let mut xs = Vec::new();
    let mut s: i64 = 7;
    for _ in 0..n {
        s = next(s);
        xs.push(i32::try_from((s / 4294967296) % 1000003).unwrap());
    }
    xs
}

fn smooth(xs: &mut [u8], rounds: i64) {
    for _ in 0..rounds {
        for i in 1..xs.len() {
            xs[i] = u8::try_from((xs[i] as i64 + xs[i - 1] as i64) / 2).unwrap();
        }
    }
}

fn mix(xs: &mut [i32], rounds: i64) {
    for _ in 0..rounds {
        for i in 1..xs.len() {
            xs[i] = i32::try_from((xs[i] as i64 * 3 + xs[i - 1] as i64) % 1000003).unwrap();
        }
    }
}

fn fnv(xs: &[u8], seed: i64) -> i64 {
    let mut h: u32 = u32::try_from(2166136261 + seed).unwrap();
    for &b in xs {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    h as i64
}

fn main() {
    let mut args = env::args().skip(1);
    let n: i64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(1_000_000);
    let rounds: i64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(100);
    let mut bs = bytes(n);
    let mut is = ints(n);
    smooth(&mut bs, rounds);
    mix(&mut is, rounds);
    println!("{}", bs.iter().map(|&x| x as i64).sum::<i64>());
    println!("{}", is.iter().map(|&x| x as i64).sum::<i64>());
    let mut h: i64 = 0;
    for r in 0..rounds {
        h = (h + fnv(&bs, r)) % 4294967296;
    }
    println!("{}", h);
}
