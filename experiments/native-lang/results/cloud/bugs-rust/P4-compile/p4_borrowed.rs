// The other safe shape: on_cancel_done borrows the op (&mut Op). Then it
// cannot free it at all: `drop(op)` drops only the reference (a no-op,
// clippy::drop_ref warns), and Box::from_raw needs unsafe and a raw pointer.
struct Op { slot: u32, had_cancel: bool }
struct Core { cancel_done: u64, free: Vec<u32> }
impl Core {
    fn on_cancel_done(&mut self, op: &mut Op) {
        self.cancel_done += 1;
        #[allow(dropping_references)]
        drop(op); // PLANT P4 attempt: frees nothing
    }
    fn deliver(&mut self, mut op: Box<Op>) {
        if op.had_cancel { self.on_cancel_done(&mut op); }
        self.free.push(op.slot);
        drop(op);
    }
}
fn main() {
    let mut c = Core { cancel_done: 0, free: vec![] };
    c.deliver(Box::new(Op { slot: 1, had_cancel: true }));
    assert_eq!(c.free, vec![1]);
}
