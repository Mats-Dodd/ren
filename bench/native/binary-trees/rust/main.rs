// Binary trees, from the Benchmarks Game, on one thread: many perfect
// trees made and dropped at each depth, while one long-lived tree stays.
// With std only, so each node is a Box, not an arena. A tip is `None`,
// so it costs no allocation, as a constructor without fields doesn't.

use std::env;

struct Node {
    left: Option<Box<Node>>,
    right: Option<Box<Node>>,
}

// a perfect tree `depth` deep
fn make(depth: i64) -> Box<Node> {
    if depth > 0 {
        Box::new(Node {
            left: Some(make(depth - 1)),
            right: Some(make(depth - 1)),
        })
    } else {
        Box::new(Node {
            left: None,
            right: None,
        })
    }
}

// how many nodes it has
fn check(t: &Node) -> i64 {
    match (&t.left, &t.right) {
        (Some(l), Some(r)) => check(l) + check(r) + 1,
        _ => 1,
    }
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(21);
    let min_depth = 4;
    let max_depth = if n > min_depth + 2 { n } else { min_depth + 2 };
    let stretch = max_depth + 1;
    println!(
        "stretch tree of depth {}\t check: {}",
        stretch,
        check(&make(stretch))
    );
    let long = make(max_depth);
    let mut depth = min_depth;
    while depth <= max_depth {
        let iterations = 1i64 << (max_depth - depth + min_depth);
        let mut total = 0;
        for _ in 0..iterations {
            total += check(&make(depth));
        }
        println!(
            "{}\t trees of depth {}\t check: {}",
            iterations, depth, total
        );
        depth += 2;
    }
    println!(
        "long lived tree of depth {}\t check: {}",
        max_depth,
        check(&long)
    );
}
