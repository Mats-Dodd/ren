// mt.c's twin in Rust: the same tree and modes, counted with Arc (every
// count atomic) or read through & (no counting).
//
//   mt-rust <a-owned|a-borrowed|b|c|d> <threads> <depth> <rounds>
//
// sum_owned takes the node by Arc and clones its children's Arcs before
// dropping its own, as Perceus's owned match does on a node it doesn't
// hold alone; sum_borrowed takes &Node.

use std::sync::{Arc, Barrier};
use std::time::Instant;

// Leaf is None, no allocation, as Ren's Leaf is a scalar
struct Node(Tree, i64, Tree);
type Tree = Option<Arc<Node>>;

fn make(lo: i64, hi: i64) -> Tree {
    if lo >= hi {
        return None;
    }
    let mid = lo + (hi - lo) / 2;
    let l = make(lo, mid);
    let r = make(mid + 1, hi);
    Some(Arc::new(Node(l, mid, r)))
}

#[inline(never)]
fn sum_borrowed(t: &Tree) -> i64 {
    match t {
        Some(n) => sum_borrowed(&n.0)
            .checked_add(n.1)
            .unwrap()
            .checked_add(sum_borrowed(&n.2))
            .unwrap(),
        None => 0,
    }
}

#[inline(never)]
fn sum_owned(t: Tree) -> i64 {
    let (l, k, r) = match &t {
        Some(n) => (n.0.clone(), n.1, n.2.clone()),
        None => return 0,
    };
    drop(t);
    sum_owned(l)
        .checked_add(k)
        .unwrap()
        .checked_add(sum_owned(r))
        .unwrap()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args[1].clone();
    let threads: usize = args[2].parse().unwrap();
    let depth: u32 = args[3].parse().unwrap();
    let rounds: i64 = args[4].parse().unwrap();
    let n: i64 = (1i64 << depth) - 1;
    let shared: Tree = if mode == "b" || mode == "c" || mode == "d" {
        make(0, n)
    } else {
        None
    };
    let gate = Barrier::new(threads + 1);
    let expect = n * (n - 1) / 2 * rounds;
    let secs = std::thread::scope(|s| {
        let mut hs = Vec::new();
        for _ in 0..threads {
            let gate = &gate;
            let shared = shared.clone();
            let mode = mode.as_str();
            let h = std::thread::Builder::new()
                .stack_size(64 << 20)
                .spawn_scoped(s, move || {
                    let own: Tree = if mode.starts_with('a') { make(0, n) } else { None };
                    gate.wait();
                    let mut acc = 0i64;
                    for _ in 0..rounds {
                        acc += match mode {
                            "a-owned" => sum_owned(own.clone()),
                            "a-borrowed" => sum_borrowed(&own),
                            "b" => sum_owned(shared.clone()),
                            "c" => sum_borrowed(&shared),
                            "d" => {
                                let root = shared.clone();
                                let v = sum_borrowed(&root);
                                drop(root);
                                v
                            }
                            _ => panic!("no mode {}", mode),
                        };
                    }
                    gate.wait();
                    acc
                })
                .unwrap();
            hs.push(h);
        }
        gate.wait();
        let t0 = Instant::now();
        gate.wait();
        let secs = t0.elapsed().as_secs_f64();
        for h in hs {
            assert_eq!(h.join().unwrap(), expect);
        }
        secs
    });
    println!(
        "{},{},{},{},{:.4},{:.4e}",
        mode,
        threads,
        depth,
        rounds,
        secs,
        n as f64 * rounds as f64 * threads as f64 / secs
    );
}
