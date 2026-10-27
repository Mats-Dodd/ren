// H5: a kernel over two slices it changes and one it reads, in a loop.
// Two `&mut` can't alias, as two `&` arguments in Ren can't.

use std::env;

fn step(a: &mut [i64], b: &mut [i64], c: &[i64]) {
    for i in 0..a.len() {
        a[i] = (a[i] + b[i] * c[i]) % 65536;
        b[i] = (b[i] + a[i]) % 65536;
    }
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2_000_000);
    let mut a: Vec<i64> = (0..1000).collect();
    let mut b: Vec<i64> = (0..1000).map(|i| 1000 - i).collect();
    let c: Vec<i64> = (0..1000).map(|i| i % 13).collect();
    for _ in 0..n {
        step(&mut a, &mut b, &c);
    }
    println!("{}", a.iter().sum::<i64>() + b.iter().sum::<i64>());
}
