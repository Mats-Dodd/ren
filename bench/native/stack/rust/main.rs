// H8's kernels: a small object built, used and dropped each round. Rust
// keeps each one in the frame, as a good programmer writes it: a struct
// that borrows its string, an Option, a tuple, a closure given by
// generic parameter.

use std::env;

struct Line<'a> {
    item: &'a str,
    qty: i64,
    cents: i64,
}

fn subtotal(l: &Line) -> i64 {
    l.qty * l.cents + l.item.len() as i64
}

fn records(items: &[&str], n: i64) -> i64 {
    let mut sum = 0;
    for i in 0..n {
        let l = Line { item: items[(i % items.len() as i64) as usize], qty: i % 7, cents: i % 13 };
        sum = (sum + subtotal(&l)) % 1_000_000_007;
    }
    sum
}

fn price_of(i: i64) -> Option<i64> {
    if i % 3 == 0 { None } else { Some(i % 101) }
}

fn options(n: i64) -> i64 {
    let mut sum = 0;
    for i in 0..n {
        match price_of(i) {
            Some(p) => sum = (sum + p) % 1_000_000_007,
            None => sum = (sum + 1) % 1_000_000_007,
        }
    }
    sum
}

fn pick<'a>(items: &[&'a str], i: i64) -> (&'a str, i64) {
    (items[(i % items.len() as i64) as usize], i % 1000)
}

fn tuples(items: &[&str], n: i64) -> i64 {
    let mut sum = 0;
    for i in 0..n {
        let (s, k) = pick(items, i);
        sum = (sum + s.len() as i64 + k) % 1_000_000_007;
    }
    sum
}

fn with_line<F: Fn(&Line) -> i64>(l: &Line, f: F) -> i64 {
    f(l)
}

fn blocks(items: &[&str], n: i64) -> i64 {
    let mut sum = 0;
    let markup = 3;
    for i in 0..n {
        let l = Line { item: items[(i % items.len() as i64) as usize], qty: i % 5, cents: i % 11 };
        sum = (sum + with_line(&l, |x| x.qty * x.cents * markup + x.item.len() as i64)) % 1_000_000_007;
    }
    sum
}

fn main() {
    let n: i64 = env::args().nth(1).map(|s| s.parse().unwrap()).unwrap_or(50_000_000);
    let kernel = env::args().nth(2).unwrap_or_default();
    let items = ["apple", "pear", "fig", "quince"];
    if kernel.is_empty() || kernel == "records" { println!("{}", records(&items, n)); }
    if kernel.is_empty() || kernel == "options" { println!("{}", options(n)); }
    if kernel.is_empty() || kernel == "tuples" { println!("{}", tuples(&items, n)); }
    if kernel.is_empty() || kernel == "blocks" { println!("{}", blocks(&items, n)); }
}
