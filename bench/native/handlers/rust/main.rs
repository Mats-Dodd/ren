// H2: n calls of a counter's `bump`, through a trait the loop is generic
// over, so rustc calls the one implementation directly, as Ren's release
// build means to with a known handler; next to the same loop calling a
// plain function.

use std::env;

trait Counter {
    fn bump(&mut self, k: i64) -> i64;
}

// adds up what it's given, and says the total so far
struct Total {
    total: i64,
}

impl Counter for Total {
    fn bump(&mut self, k: i64) -> i64 {
        self.total += k;
        self.total
    }
}

fn count_with_handler(c: &mut impl Counter, n: i64) -> i64 {
    let mut last = 0;
    for i in 0..n {
        last = c.bump(i % 7);
    }
    last
}

fn bump(total: i64, k: i64) -> i64 {
    total + k
}

fn count_with_function(n: i64) -> i64 {
    let mut total = 0;
    for i in 0..n {
        total = bump(total, i % 7);
    }
    total
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1_000_000_000);
    println!("{}", count_with_handler(&mut Total { total: 0 }, n));
    println!("{}", count_with_function(n));
}
