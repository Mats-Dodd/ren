// Symbolic differentiation: Koka's deriv benchmark
// (test/bench/koka/deriv.kk). Terms share their parts, so they're
// counted with Rc.

use std::env;
use std::rc::Rc;

enum Expr {
    Val(i64),
    Var(String),
    Add(Rc<Expr>, Rc<Expr>),
    Mul(Rc<Expr>, Rc<Expr>),
    Pow(Rc<Expr>, Rc<Expr>),
    Ln(Rc<Expr>),
}

use Expr::*;

type E = Rc<Expr>;

fn val(n: i64) -> E {
    Rc::new(Val(n))
}

// `a` to the power `b`, by squaring; a negative `b` counts as 0 or 1
fn pown(a: i64, b: i64) -> i64 {
    if b == 0 {
        1
    } else if b == 1 {
        a
    } else {
        let y = pown(a, b / 2);
        y * y * (if b % 2 == 0 { 1 } else { a })
    }
}

fn add(n0: &E, m0: &E) -> E {
    match (&**n0, &**m0) {
        (Val(n), Val(m)) => val(n + m),
        (Val(0), _) => m0.clone(),
        (_, Val(0)) => n0.clone(),
        (_, Val(_)) => add(m0, n0),
        (Val(n), Add(l, f)) if matches!(**l, Val(_)) => {
            let Val(m) = **l else { unreachable!() };
            add(&val(n + m), f)
        }
        (_, Add(l, g)) if matches!(**l, Val(_)) => add(l, &add(n0, g)),
        (Add(f, g), _) => add(f, &add(g, m0)),
        _ => Rc::new(Add(n0.clone(), m0.clone())),
    }
}

fn mul(n0: &E, m0: &E) -> E {
    match (&**n0, &**m0) {
        (Val(n), Val(m)) => val(n * m),
        (Val(0), _) => val(0),
        (_, Val(0)) => val(0),
        (Val(1), _) => m0.clone(),
        (_, Val(1)) => n0.clone(),
        (_, Val(_)) => mul(m0, n0),
        (Val(n), Mul(l, f)) if matches!(**l, Val(_)) => {
            let Val(m) = **l else { unreachable!() };
            mul(&val(n * m), f)
        }
        (_, Mul(l, g)) if matches!(**l, Val(_)) => mul(l, &mul(n0, g)),
        (Mul(f, g), _) => mul(f, &mul(g, m0)),
        _ => Rc::new(Mul(n0.clone(), m0.clone())),
    }
}

fn powr(m0: &E, n0: &E) -> E {
    match (&**m0, &**n0) {
        (Val(m), Val(n)) => val(pown(*m, *n)),
        (_, Val(0)) => val(1),
        (_, Val(1)) => m0.clone(),
        (Val(0), _) => val(0),
        _ => Rc::new(Pow(m0.clone(), n0.clone())),
    }
}

fn ln(n: &E) -> E {
    match **n {
        Val(1) => val(0),
        _ => Rc::new(Ln(n.clone())),
    }
}

fn d(x: &str, e: &E) -> E {
    match &**e {
        Val(_) => val(0),
        Var(y) => val(if x == y { 1 } else { 0 }),
        Add(f, g) => add(&d(x, f), &d(x, g)),
        Mul(f, g) => add(&mul(f, &d(x, g)), &mul(g, &d(x, f))),
        Pow(f, g) => mul(
            &powr(f, g),
            &add(
                &mul(&mul(g, &d(x, f)), &powr(f, &val(-1))),
                &mul(&ln(f), &d(x, g)),
            ),
        ),
        Ln(f) => mul(&d(x, f), &powr(f, &val(-1))),
    }
}

fn count(e: &Expr) -> i64 {
    match e {
        Val(_) | Var(_) => 1,
        Add(f, g) | Mul(f, g) | Pow(f, g) => count(f) + count(g),
        Ln(f) => count(f),
    }
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    let x = Rc::new(Var("x".to_string()));
    let mut e = powr(&x, &x);
    for i in 0..n {
        e = d("x", &e);
        println!("{} count: {}", i + 1, count(&e));
    }
    println!("done");
}
