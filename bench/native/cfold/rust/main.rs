// Constant folding: Koka's cfold benchmark (test/bench/koka/cfold.kk).
// Each pass takes the tree it's given and builds a new one. Reassociating
// makes a chain of 2^n nodes, which the recursion walks down, so the work
// runs on a thread with a large stack, as Koka's and Go's grow theirs.

use std::env;
use std::thread;

// a `Var`'s name is never read, as in the original
#[allow(dead_code)]
enum Expr {
    Var(i64),
    Val(i64),
    Add(Box<Expr>, Box<Expr>),
    Mul(Box<Expr>, Box<Expr>),
}

use Expr::*;

fn mk_expr(n: i64, v: i64) -> Box<Expr> {
    if n == 0 {
        Box::new(if v == 0 { Var(1) } else { Val(v) })
    } else {
        Box::new(Add(
            mk_expr(n - 1, v + 1),
            mk_expr(n - 1, if v > 1 { v - 1 } else { 0 }),
        ))
    }
}

fn append_add(e0: Box<Expr>, e3: Box<Expr>) -> Box<Expr> {
    match *e0 {
        Add(e1, e2) => Box::new(Add(e1, append_add(e2, e3))),
        e0 => Box::new(Add(Box::new(e0), e3)),
    }
}

fn append_mul(e0: Box<Expr>, e3: Box<Expr>) -> Box<Expr> {
    match *e0 {
        Mul(e1, e2) => Box::new(Mul(e1, append_mul(e2, e3))),
        e0 => Box::new(Mul(Box::new(e0), e3)),
    }
}

fn reassoc(e: Box<Expr>) -> Box<Expr> {
    match *e {
        Add(e1, e2) => append_add(reassoc(e1), reassoc(e2)),
        Mul(e1, e2) => append_mul(reassoc(e1), reassoc(e2)),
        e => Box::new(e),
    }
}

fn cfold(e: Box<Expr>) -> Box<Expr> {
    match *e {
        Add(e1, e2) => {
            let a = cfold(e1);
            let b = cfold(e2);
            match (*a, *b) {
                (Val(x), Val(y)) => Box::new(Val(x + y)),
                (Val(x), Add(f, g)) if matches!(*g, Val(_)) => {
                    let Val(y) = *g else { unreachable!() };
                    Box::new(Add(Box::new(Val(x + y)), f))
                }
                (Val(x), Add(f, g)) if matches!(*f, Val(_)) => {
                    let Val(y) = *f else { unreachable!() };
                    Box::new(Add(Box::new(Val(x + y)), g))
                }
                (a, b) => Box::new(Add(Box::new(a), Box::new(b))),
            }
        }
        Mul(e1, e2) => {
            let a = cfold(e1);
            let b = cfold(e2);
            match (*a, *b) {
                (Val(x), Val(y)) => Box::new(Val(x * y)),
                (Val(x), Mul(f, g)) if matches!(*g, Val(_)) => {
                    let Val(y) = *g else { unreachable!() };
                    Box::new(Mul(Box::new(Val(x * y)), f))
                }
                (Val(x), Mul(f, g)) if matches!(*f, Val(_)) => {
                    let Val(y) = *f else { unreachable!() };
                    Box::new(Mul(Box::new(Val(x * y)), g))
                }
                (a, b) => Box::new(Mul(Box::new(a), Box::new(b))),
            }
        }
        e => Box::new(e),
    }
}

fn eval(e: &Expr) -> i64 {
    match e {
        Var(_) => 0,
        Val(v) => *v,
        Add(l, r) => eval(l) + eval(r),
        Mul(l, r) => eval(l) * eval(r),
    }
}

// The chain is dropped a node at a time, down its right side.
fn drop_chain(mut e: Box<Expr>) {
    loop {
        match *e {
            Add(_, r) | Mul(_, r) => e = r,
            _ => return,
        }
    }
}

fn run(n: i64) {
    let e = mk_expr(n, 1);
    println!("{}", eval(&e));
    let folded = cfold(reassoc(e));
    println!("{}", eval(&folded));
    drop_chain(folded);
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    let worker = thread::Builder::new()
        .stack_size(1 << 30)
        .spawn(move || run(n));
    worker.unwrap().join().unwrap();
}
