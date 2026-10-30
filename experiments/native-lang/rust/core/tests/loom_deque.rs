//! loom model of the Chase-Lev deque (SPEC §A.3). Run with
//!   RUSTFLAGS="--cfg loom" cargo test -p ren_core --release --test loom_deque
//! Under --cfg loom the crate builds only the deque, on loom's atomics.
//! Each model checks the deque's one invariant: every pushed item comes
//! out exactly once (take, steal or the final drain), never twice, never
//! lost, and a fresh deque's take is EMPTY (P2).
#![cfg(loom)]
use loom::sync::Arc;
use loom::thread;
use ren_core::deque::{Deque, ABORT, EMPTY};

fn drain(q: &Deque, got: &mut Vec<u64>) {
    loop {
        let x = q.take();
        if x == EMPTY {
            break;
        }
        got.push(x);
    }
}
fn check(mut got: Vec<u64>, n: u64) {
    got.retain(|&x| x != EMPTY && x != ABORT);
    got.sort_unstable();
    assert_eq!(got, (1..=n).collect::<Vec<_>>(), "an item was lost or taken twice");
}

/// The last-element race: owner take vs one thief, after a fresh-deque take.
#[test]
fn take_vs_steal_last() {
    loom::model(|| {
        let q = Arc::new(Deque::new(1));
        assert_eq!(q.take(), EMPTY);
        q.push(1);
        let q2 = q.clone();
        let th = thread::spawn(move || q2.steal());
        let mut got = vec![q.take()];
        got.push(th.join().unwrap());
        drain(&q, &mut got);
        check(got, 1);
    });
}

/// Growth while a thief reads (the CDSChecker window): capacity 1, so the
/// second push grows the ring with a steal in flight.
#[test]
fn steal_during_grow() {
    loom::model(|| {
        let q = Arc::new(Deque::new(0));
        q.push(1);
        let q2 = q.clone();
        let th = thread::spawn(move || q2.steal());
        q.push(2);
        q.push(3);
        let mut got = vec![q.take()];
        got.push(th.join().unwrap());
        drain(&q, &mut got);
        check(got, 3);
    });
}

/// Two thieves and the owner on two items.
#[test]
fn two_thieves() {
    let mut b = loom::model::Builder::new();
    b.preemption_bound = Some(3);
    b.check(|| {
        let q = Arc::new(Deque::new(1));
        q.push(1);
        q.push(2);
        let ths: Vec<_> = (0..2)
            .map(|_| {
                let q = q.clone();
                thread::spawn(move || q.steal())
            })
            .collect();
        let mut got = vec![q.take()];
        for t in ths {
            got.push(t.join().unwrap());
        }
        drain(&q, &mut got);
        check(got, 2);
    });
}
