// P4 in owned Rust: what `deliver`/`on_cancel_done` look like if the op
// record travels as Box<Op> instead of *mut Op (the core's raw-pointer form).
struct Op { slot: u32, had_cancel: bool }
struct Core { cancel_done: u64, free: Vec<u32> }
impl Core {
    fn on_cancel_done(&mut self, op: Box<Op>) {
        self.cancel_done += 1;
        drop(op); // PLANT P4: also free the op record
    }
    fn deliver(&mut self, op: Box<Op>) {
        if op.had_cancel {
            self.on_cancel_done(op);
        }
        self.free.push(op.slot); // the common path still uses it...
        drop(op);                // ...and frees it again
    }
}
fn main() {
    let mut c = Core { cancel_done: 0, free: vec![] };
    c.deliver(Box::new(Op { slot: 1, had_cancel: true }));
}
