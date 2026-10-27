// Arrays of arrays changed where they are, and lists built by
// recursion. The grid is a Vec of Vecs written by index; `map` maps it
// with `into_iter().map(..).collect()`, which reuses each Vec's buffer;
// the list is a Box list built front to back through a `&mut` to the
// next empty link, and scaled in place through one, as a good Rust
// programmer writes a list too long to recurse over.

use std::env;

const M: i64 = 1000003;

enum List {
    Cons(i64, Box<List>),
    Nil,
}

fn grid_of(n: i64) -> Vec<Vec<i64>> {
    (0..n).map(|i| (0..n).map(|j| i * n + j).collect()).collect()
}

fn total(g: &[Vec<i64>]) -> i64 {
    let mut s = 0;
    for row in g {
        for &x in row {
            s = (s + x) % M;
        }
    }
    s
}

fn grid(rounds: i64) -> i64 {
    let mut g = grid_of(100);
    for r in 0..rounds {
        for i in 0..100 {
            for j in 0..100 {
                g[i][j] = (g[i][j] * 31 + i as i64 + j as i64 + r) % M;
            }
        }
    }
    total(&g)
}

fn map(rounds: i64) -> i64 {
    let mut g = grid_of(100);
    for r in 0..rounds {
        g = g
            .into_iter()
            .map(|row| row.into_iter().map(|x| (x * 7 + r) % M).collect())
            .collect();
    }
    total(&g)
}

fn build(n: i64) -> List {
    let mut head = List::Nil;
    let mut at = &mut head;
    for i in 0..n {
        *at = List::Cons(i, Box::new(List::Nil));
        match at {
            List::Cons(_, t) => at = t,
            List::Nil => unreachable!(),
        }
    }
    head
}

fn scale(mut l: List, k: i64) -> List {
    let mut at = &mut l;
    while let List::Cons(h, t) = at {
        *h = *h * k % M;
        at = t;
    }
    l
}

fn sum(l: &List) -> i64 {
    let mut s = 0;
    let mut c = l;
    while let List::Cons(h, t) = c {
        s = (s + h) % M;
        c = t;
    }
    s
}

// a long list dropped by a loop, not by recursion
fn free(mut l: List) {
    while let List::Cons(_, t) = l {
        l = *t;
    }
}

fn list(rounds: i64, n: i64) -> i64 {
    let mut s = 0;
    for r in 0..rounds {
        let l = scale(build(n), r + 2);
        s = (s + sum(&l)) % M;
        free(l);
    }
    s
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1000);
    println!("{}", grid(n * 10));
    println!("{}", map(n * 10));
    println!("{}", list(n / 10 + 1, 1000 * n));
}
