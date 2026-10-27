// H1: each kernel written with a closure, next to its twin written as a
// plain loop, as in bench.ren. Closures are generic parameters, so rustc
// specializes and inlines them: what Ren's release build means to do.

use std::env;

enum Tree {
    Node(Box<Tree>, i64, Box<Tree>),
    Leaf,
}

use Tree::*;

fn build(lo: i64, hi: i64) -> Tree {
    if lo >= hi {
        Leaf
    } else {
        let mid = (lo + hi) / 2;
        Node(
            Box::new(build(lo, mid)),
            mid % 1000,
            Box::new(build(mid + 1, hi)),
        )
    }
}

fn fold_tree<A>(t: &Tree, acc: A, f: &impl Fn(A, i64) -> A) -> A {
    match t {
        Node(l, v, r) => {
            let acc = fold_tree(l, acc, f);
            fold_tree(r, f(acc, *v), f)
        }
        Leaf => acc,
    }
}

fn sum_tree(t: &Tree, acc: i64, k: i64) -> i64 {
    match t {
        Node(l, v, r) => sum_tree(r, sum_tree(l, acc, k) + v * k, k),
        Leaf => acc,
    }
}

// `body` until it gives something other than 0, `n` times at most
fn attempt_n(n: i64, mut body: impl FnMut() -> i64) -> i64 {
    let mut result = 0;
    let mut tries = 0;
    while tries < n && result == 0 {
        result = body();
        tries += 1;
    }
    result
}

fn map_blocks(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        let ys: Vec<i64> = xs.iter().map(|x| x * k + 1).collect();
        total += ys[(round as usize) % ys.len()];
    }
    total
}

fn map_loop(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        let mut ys = Vec::new();
        for x in xs {
            ys.push(x * k + 1);
        }
        total += ys[(round as usize) % ys.len()];
    }
    total
}

fn reduce_blocks(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        total += xs.iter().fold(0, |acc, x| acc + x * k);
    }
    total
}

fn reduce_loop(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        let mut acc = 0;
        for x in xs {
            acc += x * k;
        }
        total += acc;
    }
    total
}

fn each_blocks(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        xs.iter().for_each(|x| total += x * k);
    }
    total
}

fn each_loop(xs: &[i64], n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        for x in xs {
            total += x * k;
        }
    }
    total
}

fn fold_blocks(t: &Tree, n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        let k = round % 4;
        total += fold_tree(t, 0, &|acc, v| acc + v * k);
    }
    total
}

fn fold_loop(t: &Tree, n: i64) -> i64 {
    let mut total = 0;
    for round in 0..n {
        total += sum_tree(t, 0, round % 4);
    }
    total
}

fn attempt_blocks(n: i64) -> i64 {
    let mut total = 0;
    let mut calls = 0;
    for i in 0..n * 1000 {
        total += attempt_n(3, || {
            calls += 1;
            (i + calls) % 3
        });
    }
    total + calls
}

fn attempt_loop(n: i64) -> i64 {
    let mut total = 0;
    let mut calls = 0;
    for i in 0..n * 1000 {
        let mut result = 0;
        let mut tries = 0;
        while tries < 3 && result == 0 {
            calls += 1;
            result = (i + calls) % 3;
            tries += 1;
        }
        total += result;
    }
    total + calls
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(100_000);
    let xs: Vec<i64> = (0..1000).map(|i| i * 7 % 1000).collect();
    let t = build(0, 1000);
    println!("map {} {}", map_blocks(&xs, n), map_loop(&xs, n));
    println!("reduce {} {}", reduce_blocks(&xs, n), reduce_loop(&xs, n));
    println!("each {} {}", each_blocks(&xs, n), each_loop(&xs, n));
    println!("fold {} {}", fold_blocks(&t, n), fold_loop(&t, n));
    println!("attempt {} {}", attempt_blocks(n), attempt_loop(n));
}
