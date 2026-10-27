// A red-black tree, built by inserting n keys: Koka's rbtree benchmark
// (test/bench/koka/rbtree.kk). Each insert owns the tree, so nodes are
// changed in place, as Perceus's reuse would.

use std::env;
use std::mem;

#[derive(Clone, Copy, PartialEq)]
enum Color {
    Red,
    Black,
}

enum Tree {
    Leaf,
    Node(Box<Node>),
}

struct Node {
    color: Color,
    left: Tree,
    key: i64,
    value: bool,
    right: Tree,
}

use Color::*;

fn take(t: &mut Tree) -> Tree {
    mem::replace(t, Tree::Leaf)
}

fn is_red(t: &Tree) -> bool {
    matches!(t, Tree::Node(n) if n.color == Red)
}

// `l` is the new left child of `p`, whose own left is empty
fn balance_left(l: Tree, mut p: Box<Node>) -> Tree {
    let Tree::Node(mut l) = l else {
        return Tree::Leaf;
    };
    if is_red(&l.left) {
        let Tree::Node(mut ll) = take(&mut l.left) else {
            unreachable!()
        };
        ll.color = Black;
        p.left = take(&mut l.right);
        p.color = Black;
        l.left = Tree::Node(ll);
        l.right = Tree::Node(p);
        l.color = Red;
        Tree::Node(l)
    } else if is_red(&l.right) {
        let Tree::Node(mut lr) = take(&mut l.right) else {
            unreachable!()
        };
        l.right = take(&mut lr.left);
        l.color = Black;
        p.left = take(&mut lr.right);
        p.color = Black;
        lr.left = Tree::Node(l);
        lr.right = Tree::Node(p);
        lr.color = Red;
        Tree::Node(lr)
    } else {
        l.color = Red;
        p.left = Tree::Node(l);
        p.color = Black;
        Tree::Node(p)
    }
}

// `r` is the new right child of `p`, whose own right is empty
fn balance_right(mut p: Box<Node>, r: Tree) -> Tree {
    let Tree::Node(mut r) = r else {
        return Tree::Leaf;
    };
    if is_red(&r.left) {
        let Tree::Node(mut rl) = take(&mut r.left) else {
            unreachable!()
        };
        p.right = take(&mut rl.left);
        p.color = Black;
        r.left = take(&mut rl.right);
        r.color = Black;
        rl.left = Tree::Node(p);
        rl.right = Tree::Node(r);
        rl.color = Red;
        Tree::Node(rl)
    } else if is_red(&r.right) {
        let Tree::Node(mut rr) = take(&mut r.right) else {
            unreachable!()
        };
        rr.color = Black;
        p.right = take(&mut r.left);
        p.color = Black;
        r.left = Tree::Node(p);
        r.right = Tree::Node(rr);
        r.color = Red;
        Tree::Node(r)
    } else {
        r.color = Red;
        p.right = Tree::Node(r);
        p.color = Black;
        Tree::Node(p)
    }
}

fn ins(t: Tree, k: i64, v: bool) -> Tree {
    let Tree::Node(mut n) = t else {
        return Tree::Node(Box::new(Node {
            color: Red,
            left: Tree::Leaf,
            key: k,
            value: v,
            right: Tree::Leaf,
        }));
    };
    if k < n.key {
        if n.color == Black && is_red(&n.left) {
            let l = ins(take(&mut n.left), k, v);
            return balance_left(l, n);
        }
        n.left = ins(take(&mut n.left), k, v);
    } else if k > n.key {
        if n.color == Black && is_red(&n.right) {
            let r = ins(take(&mut n.right), k, v);
            return balance_right(n, r);
        }
        n.right = ins(take(&mut n.right), k, v);
    } else {
        n.key = k;
        n.value = v;
    }
    Tree::Node(n)
}

fn insert(t: Tree, k: i64, v: bool) -> Tree {
    let mut t = ins(t, k, v);
    if let Tree::Node(n) = &mut t {
        n.color = Black;
    }
    t
}

fn fold<A>(t: &Tree, acc: A, f: &impl Fn(i64, bool, A) -> A) -> A {
    match t {
        Tree::Node(n) => {
            let acc = fold(&n.left, acc, f);
            let acc = f(n.key, n.value, acc);
            fold(&n.right, acc, f)
        }
        Tree::Leaf => acc,
    }
}

fn make_tree(n: i64) -> Tree {
    let mut t = Tree::Leaf;
    let mut i = n;
    while i > 0 {
        i -= 1;
        t = insert(t, i, i % 10 == 0);
    }
    t
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(4_200_000);
    let t = make_tree(n);
    let count = fold(&t, 0i64, &|_, v, r| if v { r + 1 } else { r });
    println!("{}", count);
}
