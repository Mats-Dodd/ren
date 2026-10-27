// Every way to put n queens on an n by n board: Koka's nqueens
// benchmark (test/bench/koka/nqueens.kk). Solutions share their tails,
// so the lists are counted with Rc.

use std::env;
use std::rc::Rc;

struct Cell<T> {
    head: T,
    tail: List<T>,
}

type List<T> = Option<Rc<Cell<T>>>;

// A list of a few hundred thousand solutions is dropped a cell at a time,
// not by recursing down its tail, which would overflow the stack.
impl<T> Drop for Cell<T> {
    fn drop(&mut self) {
        let mut next = self.tail.take();
        while let Some(cell) = next {
            match Rc::try_unwrap(cell) {
                Ok(mut cell) => next = cell.tail.take(),
                Err(_) => break,
            }
        }
    }
}

fn cons<T>(head: T, tail: List<T>) -> List<T> {
    Some(Rc::new(Cell { head, tail }))
}

fn length<T>(mut xs: &List<T>) -> i64 {
    let mut n = 0;
    while let Some(cell) = xs {
        n += 1;
        xs = &cell.tail;
    }
    n
}

fn safe(queen: i64, mut diag: i64, mut xs: &List<i64>) -> bool {
    while let Some(cell) = xs {
        let q = cell.head;
        if queen == q || queen == q + diag || queen == q - diag {
            return false;
        }
        diag += 1;
        xs = &cell.tail;
    }
    true
}

fn append_safe(mut queen: i64, xs: &List<i64>, mut xss: List<List<i64>>) -> List<List<i64>> {
    while queen > 0 {
        if safe(queen, 1, xs) {
            xss = cons(cons(queen, xs.clone()), xss);
        }
        queen -= 1;
    }
    xss
}

fn find_solutions(n: i64, queen: i64) -> List<List<i64>> {
    if queen == 0 {
        return cons(None, None);
    }
    let mut acc = None;
    let xss = find_solutions(n, queen - 1);
    let mut cur = &xss;
    while let Some(cell) = cur {
        acc = append_safe(n, &cell.head, acc);
        cur = &cell.tail;
    }
    acc
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(13);
    println!("{}", length(&find_solutions(n, n)));
}
