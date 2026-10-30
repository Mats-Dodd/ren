//! The one loop shape both Linux drivers run, per worker thread (SPEC §C.1),
//! and the operations both do synchronously (PIPE, LISTEN, socket setup).
use super::{errno, Drv};
use crate::journal::Enc;
use crate::sys::*;
use core::mem::{size_of, zeroed};

pub trait Io {
    /// On this worker's thread, before the first ren_run.
    unsafe fn setup(&mut self, d: &Drv, w: i32) -> Result<(), &'static str>;
    unsafe fn submit(&mut self, d: &Drv, c: *mut ren_core, w: i32, call: &ren_call);
    fn inflight(&self) -> usize;
    /// After FINISHED with ops still in flight (a kill): cancel them all.
    unsafe fn cancel_all(&mut self, d: &Drv, c: *mut ren_core, w: i32);
    /// Wait (block = until something happens; else just poll), then reply
    /// to every completion and every due timer.
    unsafe fn wait(&mut self, d: &Drv, c: *mut ren_core, w: i32, block: bool);
    /// Only after FINISHED and inflight == 0.
    unsafe fn teardown(&mut self);
}

pub unsafe fn drive<B: Io>(d: &Drv, c: *mut ren_core, w: i32, b: &mut B) -> i32 {
    if let Err(m) = b.setup(d, w) {
        d.set_err(m);
        return -1;
    }
    if w == 0 && d.recording() {
        let mut e = Enc::new();
        e.u32(d.drv_word).u32(d.o.workers as u32).u32(d.o.steps);
        d.rec(REN_J_DRV, w, 0, &e.0);
    }
    let steps = d.o.steps;
    loop {
        let r = ren_run(c, w, steps);
        if d.recording() {
            let mut e = Enc::new();
            e.u32(steps).i32(r);
            d.rec(REN_J_RUN, w, ren_progress(c, w), &e.0);
        }
        let mut call: ren_call = zeroed();
        while ren_poll_call(c, w, &mut call) {
            d.rec_pull(c, w, &call);
            b.submit(d, c, w, &call);
        }
        d.rec(REN_J_DRAINED, w, ren_progress(c, w), &[]);
        if r == REN_FINISHED as i32 {
            if b.inflight() == 0 {
                break;
            }
            b.cancel_all(d, c, w);
            if b.inflight() == 0 {
                continue;
            }
        }
        b.wait(d, c, w, r != REN_RUNNING as i32);
    }
    b.teardown();
    0
}

/// PIPE: pipe2(O_NONBLOCK | O_CLOEXEC); res 0, a = read end, b = write end.
pub unsafe fn do_pipe() -> ren_io_result {
    let mut fds = [0i32; 2];
    if libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) < 0 {
        return super::res1(-(errno() as i64));
    }
    ren_io_result { res: 0, a: fds[0] as i64, b: fds[1] as i64 }
}

pub fn loopback(port: i64) -> libc::sockaddr_in {
    // SAFETY: sockaddr_in is plain data; all-zero is valid.
    let mut a: libc::sockaddr_in = unsafe { zeroed() };
    a.sin_family = libc::AF_INET as libc::sa_family_t;
    a.sin_port = (port as u16).to_be();
    a.sin_addr.s_addr = u32::from_be_bytes([127, 0, 0, 1]).to_be();
    a
}

pub unsafe fn tcp_socket() -> i32 {
    libc::socket(libc::AF_INET, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0)
}

/// LISTEN on 127.0.0.1:arg; res = fd, a = port.
pub unsafe fn do_listen(port: i64) -> ren_io_result {
    let fd = tcp_socket();
    if fd < 0 {
        return super::res1(-(errno() as i64));
    }
    let one: i32 = 1;
    libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, &one as *const i32 as *const _, 4);
    let mut a = loopback(port);
    let sl = size_of::<libc::sockaddr_in>() as libc::socklen_t;
    if libc::bind(fd, &a as *const _ as *const libc::sockaddr, sl) < 0 || libc::listen(fd, 128) < 0 {
        let e = errno();
        libc::close(fd);
        return super::res1(-(e as i64));
    }
    let mut l = sl;
    libc::getsockname(fd, &mut a as *mut _ as *mut libc::sockaddr, &mut l);
    ren_io_result { res: fd as i64, a: u16::from_be(a.sin_port) as i64, b: 0 }
}

/// The body of a REN_CALL (the core keeps it alive until the final reply).
pub unsafe fn body(call: &ren_call) -> ren_io_body {
    *(call.body as *const ren_io_body)
}
