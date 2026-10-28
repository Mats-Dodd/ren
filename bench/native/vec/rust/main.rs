// Loops over arrays: each kernel over slices of `n` elements, `rounds`
// times, written as Rust is usually written, with iterators where they
// fit, which need no bounds checks. Arithmetic on i64 wraps, as release
// builds' does; a store into a u8 is checked to fit, as Ren's is. The
// Float sum adds in eight lanes, as Ren's `sum` is defined to.

use std::convert::TryFrom;
use std::env;

fn dot(xs: &[f64], ys: &[f64]) -> f64 {
    let mut t = 0.0;
    for (x, y) in xs.iter().zip(ys) {
        t += x * y;
    }
    t
}

fn fsum(xs: &[f64]) -> f64 {
    let mut l = [0.0f64; 8];
    let mut chunks = xs.chunks_exact(8);
    for c in &mut chunks {
        for k in 0..8 {
            l[k] += c[k];
        }
    }
    for (k, x) in chunks.remainder().iter().enumerate() {
        l[k] += x;
    }
    ((l[0] + l[1]) + (l[2] + l[3])) + ((l[4] + l[5]) + (l[6] + l[7]))
}

fn scale(xs: &mut [f64], k: f64) {
    for x in xs.iter_mut() {
        *x *= k;
    }
}

fn axpy(ys: &mut [f64], a: f64, xs: &[f64]) {
    for (y, x) in ys.iter_mut().zip(xs) {
        *y += a * x;
    }
}

fn churn(xs: &mut [i64]) {
    for x in xs.iter_mut() {
        *x = x
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
    }
}

fn total(xs: &[i64]) -> i64 {
    xs.iter().sum()
}

fn blend(xs: &mut [u8], ys: &[u8]) {
    for (x, y) in xs.iter_mut().zip(ys) {
        *x = u8::try_from((*x as i64 + *y as i64) / 2).unwrap();
    }
}

fn milli(x: f64) -> i64 {
    (x * 1000.0).round() as i64
}

fn main() {
    let args: Vec<i64> = env::args().skip(1).map(|s| s.parse().unwrap()).collect();
    let n = *args.get(0).unwrap_or(&1000);
    let rounds = *args.get(1).unwrap_or(&1_000_000);
    let only = *args.get(2).unwrap_or(&0);
    let mut fs = Vec::new();
    let mut gs = Vec::new();
    let mut is = Vec::new();
    let mut bs = Vec::new();
    let mut cs = Vec::new();
    for i in 0..n {
        fs.push((i % 100) as f64 / 64.0);
        gs.push((i % 7) as f64 / 4.0);
        is.push(i);
        bs.push((i % 256) as u8);
        cs.push((i * 7 % 256) as u8);
    }
    if only == 0 || only == 1 {
        let mut d = 0.0;
        for _ in 0..rounds {
            d += dot(&fs, &gs);
        }
        println!("{}", milli(d));
    }
    if only == 0 || only == 2 {
        let mut s = 0.0;
        for _ in 0..rounds {
            s += fsum(&fs);
        }
        println!("{}", milli(s));
    }
    if only == 0 || only == 3 {
        let mut gs = gs.clone();
        for r in 0..rounds {
            scale(&mut gs, if r % 2 == 0 { 2.0 } else { 0.5 });
        }
        println!("{}", milli(fsum(&gs)));
    }
    if only == 0 || only == 4 {
        let mut ys = gs.clone();
        for r in 0..rounds {
            axpy(&mut ys, if r % 2 == 0 { 0.25 } else { -0.25 }, &fs);
        }
        println!("{}", milli(fsum(&ys)));
    }
    if only == 0 || only == 5 {
        let mut xs = is.clone();
        for _ in 0..rounds {
            churn(&mut xs);
        }
        println!("{}", xs[n as usize - 1] % 1000003);
    }
    if only == 0 || only == 6 {
        let mut t = 0;
        for _ in 0..rounds {
            t = (t + total(&is)) % 1000003;
        }
        println!("{}", t);
    }
    if only == 0 || only == 7 {
        let mut xs = bs.clone();
        for _ in 0..rounds {
            blend(&mut xs, &cs);
        }
        println!("{}", xs.iter().map(|&x| x as i64).sum::<i64>());
    }
}
