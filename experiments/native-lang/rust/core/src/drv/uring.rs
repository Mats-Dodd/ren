//! The io_uring driver (SPEC §C.1 table, io_uring column) on raw syscalls
//! (io_uring_setup / io_uring_enter / io_uring_register through the libc
//! crate) and the kernel's own ABI from bindgen on <linux/io_uring.h>.
//! No io_uring library. One ring per worker: created R_DISABLED in
//! ren_drv_new (so support is detected once, SPEC §2.10), enabled on the
//! worker's own thread (SINGLE_ISSUER | DEFER_TASKRUN unless refused).
use super::linux::{self, Io};
use super::{errno, mono_ns, res1, Drv, CANCELLED_RES};
use crate::sys::*;
use alloc::boxed::Box;
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::vec::Vec;
use core::cell::UnsafeCell;
use core::ffi::{c_void, CStr};
use core::mem::{size_of, zeroed};
use core::ptr::null_mut;
use core::sync::atomic::{AtomicU32, Ordering::*};

#[allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, clippy::all)]
mod k {
    include!(concat!(env!("OUT_DIR"), "/uring.rs"));
}
use k::io_uring_op as opc;

const EV_UD: u64 = u64::MAX; // the eventfd READ that carries wakes
const CANCEL_UD: u64 = u64::MAX - 1; // an ASYNC_CANCEL's own CQE: ignored
const ENTRIES: u32 = 256;

struct Ring {
    fd: i32,
    sq_ptr: *mut u8,
    sq_len: usize,
    cq_ptr: *mut u8,
    cq_len: usize,
    sqes: *mut k::io_uring_sqe,
    sqes_len: usize,
    sq_head: *const AtomicU32,
    sq_tail: *const AtomicU32,
    sq_mask: u32,
    sq_entries: u32,
    sq_array: *mut u32,
    cq_head: *const AtomicU32,
    cq_tail: *const AtomicU32,
    cq_mask: u32,
    cqes: *const k::io_uring_cqe,
    tail: u32,
    to_submit: u32,
}

unsafe fn setup_ring(flags: u32) -> Result<Ring, i32> {
    let mut p: k::io_uring_params = zeroed();
    p.flags = flags;
    let fd = libc::syscall(libc::SYS_io_uring_setup, ENTRIES, &mut p as *mut k::io_uring_params) as i32;
    if fd < 0 {
        return Err(errno());
    }
    let sq_len = p.sq_off.array as usize + p.sq_entries as usize * size_of::<u32>();
    let cq_len = p.cq_off.cqes as usize + p.cq_entries as usize * size_of::<k::io_uring_cqe>();
    let single = p.features & k::IORING_FEAT_SINGLE_MMAP != 0;
    let map = |len: usize, off: u64| -> *mut u8 {
        let m = libc::mmap(null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED | libc::MAP_POPULATE, fd, off as i64);
        if m == libc::MAP_FAILED {
            null_mut()
        } else {
            m as *mut u8
        }
    };
    let (sq_len, cq_len) = if single { (core::cmp::max(sq_len, cq_len), 0) } else { (sq_len, cq_len) };
    let sq_ptr = map(sq_len, k::IORING_OFF_SQ_RING as u64);
    let cq_ptr = if single { sq_ptr } else { map(cq_len, k::IORING_OFF_CQ_RING as u64) };
    let sqes_len = p.sq_entries as usize * size_of::<k::io_uring_sqe>();
    let sqes = map(sqes_len, k::IORING_OFF_SQES as u64) as *mut k::io_uring_sqe;
    if sq_ptr.is_null() || cq_ptr.is_null() || sqes.is_null() {
        let e = errno();
        libc::close(fd);
        return Err(e);
    }
    let at32 = |base: *mut u8, off: u32| base.add(off as usize) as *const AtomicU32;
    Ok(Ring {
        fd,
        sq_ptr,
        sq_len,
        cq_ptr,
        cq_len,
        sqes,
        sqes_len,
        sq_head: at32(sq_ptr, p.sq_off.head),
        sq_tail: at32(sq_ptr, p.sq_off.tail),
        sq_mask: *(sq_ptr.add(p.sq_off.ring_mask as usize) as *const u32),
        sq_entries: p.sq_entries,
        sq_array: sq_ptr.add(p.sq_off.array as usize) as *mut u32,
        cq_head: at32(cq_ptr, p.cq_off.head),
        cq_tail: at32(cq_ptr, p.cq_off.tail),
        cq_mask: *(cq_ptr.add(p.cq_off.ring_mask as usize) as *const u32),
        cqes: cq_ptr.add(p.cq_off.cqes as usize) as *const k::io_uring_cqe,
        tail: (*at32(sq_ptr, p.sq_off.tail)).load(Relaxed),
        to_submit: 0,
    })
}

impl Ring {
    unsafe fn enter(&mut self, min_complete: u32, getevents: bool) -> i32 {
        loop {
            let flags = if getevents { k::IORING_ENTER_GETEVENTS } else { 0 };
            let r = libc::syscall(
                libc::SYS_io_uring_enter,
                self.fd,
                self.to_submit,
                min_complete,
                flags,
                core::ptr::null::<c_void>(),
                0usize,
            ) as i32;
            if r >= 0 {
                self.to_submit -= core::cmp::min(r as u32, self.to_submit);
                return 0;
            }
            let e = errno();
            if e == libc::EINTR {
                if min_complete > 0 {
                    return 0;
                }
                continue;
            }
            return e; // EBUSY/EAGAIN: the caller reaps and retries
        }
    }
    /// The next free SQE, zeroed; flushes to the kernel when the SQ is full.
    unsafe fn sqe(&mut self) -> &mut k::io_uring_sqe {
        while self.tail.wrapping_sub((*self.sq_head).load(Acquire)) >= self.sq_entries {
            self.enter(0, false);
        }
        let i = self.tail & self.sq_mask;
        let s = &mut *self.sqes.add(i as usize);
        *s = zeroed();
        *self.sq_array.add(i as usize) = i;
        s
    }
    /// Publish the SQE taken by the last `sqe()`.
    unsafe fn push(&mut self) {
        self.tail = self.tail.wrapping_add(1);
        (*self.sq_tail).store(self.tail, Release);
        self.to_submit += 1;
    }
    unsafe fn reap(&mut self, out: &mut Vec<(u64, i32)>) {
        let mut h = (*self.cq_head).load(Relaxed);
        let t = (*self.cq_tail).load(Acquire);
        while h != t {
            let c = &*self.cqes.add((h & self.cq_mask) as usize);
            out.push((c.user_data, c.res));
            h = h.wrapping_add(1);
        }
        (*self.cq_head).store(h, Release);
    }
    unsafe fn close(&mut self) {
        if self.fd < 0 {
            return;
        }
        libc::munmap(self.sqes as *mut c_void, self.sqes_len);
        if self.cq_ptr != self.sq_ptr {
            libc::munmap(self.cq_ptr as *mut c_void, self.cq_len);
        }
        libc::munmap(self.sq_ptr as *mut c_void, self.sq_len);
        libc::close(self.fd);
        self.fd = -1;
    }
}

/// One op in flight, with the storage the kernel reads until its CQE.
struct UOp {
    op: u32,
    fd: i32,
    body: ren_io_body,
    ts: k::__kernel_timespec,
    addr: libc::sockaddr_in,
    sock: i32,
}

pub struct UrW {
    ring: Ring,
    ops: BTreeMap<u64, Box<UOp>>,
    fdcount: BTreeMap<i32, u32>,
    closing: Vec<(i32, u64)>,
    evfd: i32,
    evbuf: Box<u64>,
    poisoned: BTreeSet<i32>,
    cancel_all_sent: bool,
    cq: Vec<(u64, i32)>,
}

/// Detect once (SPEC §C.1 "detect once, fall back whole"): every worker's
/// ring is created here. Ok((rings, fell_back)).
pub unsafe fn new_rings(o: &ren_drv_opts, evfd: &[i32]) -> Result<(Box<[UnsafeCell<UrW>]>, bool), &'static CStr> {
    let full = k::IORING_SETUP_R_DISABLED | k::IORING_SETUP_SINGLE_ISSUER | k::IORING_SETUP_DEFER_TASKRUN;
    let plain = k::IORING_SETUP_R_DISABLED;
    let mut flags = if o.flags & REN_DRV_F_URING_NO_DEFER != 0 { plain } else { full };
    let mut fell_back = flags == plain;
    let mut ws: Vec<UnsafeCell<UrW>> = Vec::new();
    for &ev in evfd {
        let r = match setup_ring(flags) {
            Err(libc::EINVAL) if flags == full => {
                flags = plain;
                fell_back = true;
                setup_ring(flags)
            }
            r => r,
        };
        match r {
            Ok(ring) => ws.push(UnsafeCell::new(UrW {
                ring,
                ops: BTreeMap::new(),
                fdcount: BTreeMap::new(),
                closing: Vec::new(),
                evfd: ev,
                evbuf: Box::new(0),
                poisoned: BTreeSet::new(),
                cancel_all_sent: false,
                cq: Vec::with_capacity(64),
            })),
            Err(e) => {
                for w in ws.iter_mut() {
                    w.get_mut().ring.close();
                }
                return Err(match e {
                    libc::ENOSYS => c"io_uring unavailable: io_uring_setup returned ENOSYS (kernel without io_uring)",
                    libc::EPERM => c"io_uring unavailable: io_uring_setup returned EPERM (disabled by sysctl or seccomp)",
                    libc::EINVAL => c"io_uring_setup returned EINVAL even without SINGLE_ISSUER|DEFER_TASKRUN",
                    libc::ENOMEM => c"io_uring_setup returned ENOMEM (locked-memory limit?)",
                    _ => c"io_uring_setup failed",
                });
            }
        }
    }
    Ok((ws.into_boxed_slice(), fell_back))
}

impl UrW {
    unsafe fn arm_ev(&mut self) {
        let buf = &mut *self.evbuf as *mut u64 as u64;
        let fd = self.evfd;
        let s = self.ring.sqe();
        s.opcode = opc::IORING_OP_READ as u8;
        s.fd = fd;
        s.__bindgen_anon_2.addr = buf;
        s.len = 8;
        s.__bindgen_anon_1.off = u64::MAX;
        s.user_data = EV_UD;
        self.ring.push();
    }
    fn fd_inc(&mut self, fd: i32) {
        *self.fdcount.entry(fd).or_insert(0) += 1;
    }
    fn fd_dec(&mut self, fd: i32) {
        if let Some(n) = self.fdcount.get_mut(&fd) {
            *n -= 1;
            if *n == 0 {
                self.fdcount.remove(&fd);
            }
        }
    }
    unsafe fn rw(&mut self, opcode: u32, id: u64, u: Box<UOp>) {
        let (fd, buf, len) = (u.fd, u.body.buf, u.body.len);
        self.ops.insert(id, u);
        self.fd_inc(fd);
        let s = self.ring.sqe();
        s.opcode = opcode as u8;
        s.fd = fd;
        s.__bindgen_anon_2.addr = buf;
        s.len = len as u32;
        s.__bindgen_anon_1.off = u64::MAX; // current position (pipes, sockets)
        s.user_data = id;
        self.ring.push();
    }
    unsafe fn async_cancel(&mut self, fd: i32, target: u64, flags: u32) {
        let s = self.ring.sqe();
        s.opcode = opc::IORING_OP_ASYNC_CANCEL as u8;
        s.fd = fd;
        s.__bindgen_anon_2.addr = target;
        s.__bindgen_anon_3.cancel_flags = flags;
        s.user_data = CANCEL_UD;
        self.ring.push();
    }
    /// CLOSEs waiting for their fd's ops to drain (SPEC §C.1 table: CLOSE).
    unsafe fn closes(&mut self, d: &Drv, c: *mut ren_core, w: i32) {
        let mut i = 0;
        while i < self.closing.len() {
            let (fd, id) = self.closing[i];
            if self.fdcount.contains_key(&fd) {
                i += 1;
                continue;
            }
            self.closing.swap_remove(i);
            self.poisoned.remove(&fd);
            let r = if libc::close(fd) < 0 { -(errno() as i64) } else { 0 };
            d.reply(c, w, id, REN_DONE, res1(r), &[]);
        }
    }
    unsafe fn cqe(&mut self, d: &Drv, c: *mut ren_core, w: i32, ud: u64, res: i32) {
        if ud == EV_UD {
            self.arm_ev();
            return;
        }
        if ud == CANCEL_UD {
            return;
        }
        let Some(u) = self.ops.remove(&ud) else { return };
        self.fd_dec(u.fd);
        let ecanceled = res == -libc::ECANCELED;
        let (state, r) = match u.op {
            REN_OP_SLEEP_UNTIL if res == -libc::ETIME => (REN_DONE, res1(0)),
            REN_OP_CONNECT if res == 0 => (REN_DONE, res1(u.sock as i64)),
            REN_OP_CONNECT => {
                libc::close(u.sock);
                if ecanceled {
                    (REN_CANCELLED, CANCELLED_RES)
                } else {
                    (REN_DONE, res1(res as i64))
                }
            }
            _ if ecanceled => (REN_CANCELLED, CANCELLED_RES),
            _ => (REN_DONE, res1(res as i64)),
        };
        let inout: &[u8] = if u.op == REN_OP_READ && state == REN_DONE && res > 0 {
            core::slice::from_raw_parts(u.body.buf as usize as *const u8, res as usize)
        } else {
            &[]
        };
        let ret = d.reply(c, w, ud, state, r, inout);
        if ret == REN_RELEASE as i32 && state == REN_DONE {
            if u.op == REN_OP_ACCEPT && res >= 0 {
                libc::close(res);
            } else if u.op == REN_OP_READ && res > 0 {
                self.poisoned.insert(u.fd);
            }
        }
        if !self.closing.is_empty() {
            self.closes(d, c, w);
        }
    }
}

impl Io for UrW {
    unsafe fn setup(&mut self, _d: &Drv, _w: i32) -> Result<(), &'static str> {
        // Enable on this thread: with SINGLE_ISSUER it becomes the submitter.
        let r = libc::syscall(libc::SYS_io_uring_register, self.ring.fd, k::IORING_REGISTER_ENABLE_RINGS, core::ptr::null::<c_void>(), 0);
        if r < 0 {
            return Err("io_uring_register(ENABLE_RINGS) failed");
        }
        self.arm_ev();
        Ok(())
    }

    unsafe fn submit(&mut self, d: &Drv, c: *mut ren_core, w: i32, call: &ren_call) {
        let id = call.id;
        if call.kind as u32 == REN_CANCEL {
            // The original op's CQE is the final reply; the cancel's own is ignored.
            if self.ops.contains_key(&id) {
                self.async_cancel(-1, id, 0);
            }
            return;
        }
        let b = linux::body(call);
        let mut u = Box::new(UOp {
            op: call.op,
            fd: b.fd as i32,
            body: b,
            ts: k::__kernel_timespec { tv_sec: 0, tv_nsec: 0 },
            addr: zeroed(),
            sock: -1,
        });
        match call.op {
            REN_OP_SLEEP_UNTIL => {
                u.ts = k::__kernel_timespec { tv_sec: b.arg / 1_000_000_000, tv_nsec: b.arg % 1_000_000_000 };
                let tsp = &u.ts as *const k::__kernel_timespec as u64;
                u.fd = -1;
                self.ops.insert(id, u);
                let s = self.ring.sqe();
                s.opcode = opc::IORING_OP_TIMEOUT as u8;
                s.fd = -1;
                s.__bindgen_anon_2.addr = tsp;
                s.len = 1;
                s.__bindgen_anon_1.off = 0; // count 0: a pure timer
                s.__bindgen_anon_3.timeout_flags = k::IORING_TIMEOUT_ABS;
                s.user_data = id;
                self.ring.push();
            }
            REN_OP_MONO_NOW => {
                d.reply(c, w, id, REN_DONE, res1(mono_ns()), &[]);
            }
            REN_OP_PIPE => {
                d.reply(c, w, id, REN_DONE, linux::do_pipe(), &[]);
            }
            REN_OP_LISTEN => {
                d.reply(c, w, id, REN_DONE, linux::do_listen(b.arg), &[]);
            }
            REN_OP_READ if self.poisoned.contains(&u.fd) => {
                d.reply(c, w, id, REN_DONE, res1(-(libc::EIO as i64)), &[]);
            }
            REN_OP_READ => self.rw(opc::IORING_OP_READ, id, u),
            REN_OP_WRITE => self.rw(opc::IORING_OP_WRITE, id, u),
            REN_OP_ACCEPT => {
                let fd = u.fd;
                self.ops.insert(id, u);
                self.fd_inc(fd);
                let s = self.ring.sqe();
                s.opcode = opc::IORING_OP_ACCEPT as u8;
                s.fd = fd;
                s.__bindgen_anon_3.accept_flags = (libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC) as u32;
                s.user_data = id;
                self.ring.push();
            }
            REN_OP_CONNECT => {
                let sock = linux::tcp_socket();
                if sock < 0 {
                    d.reply(c, w, id, REN_DONE, res1(-(errno() as i64)), &[]);
                    return;
                }
                u.sock = sock;
                u.fd = sock;
                u.addr = linux::loopback(b.arg);
                let ap = &u.addr as *const libc::sockaddr_in as u64;
                self.ops.insert(id, u);
                self.fd_inc(sock);
                let s = self.ring.sqe();
                s.opcode = opc::IORING_OP_CONNECT as u8;
                s.fd = sock;
                s.__bindgen_anon_2.addr = ap;
                s.__bindgen_anon_1.off = size_of::<libc::sockaddr_in>() as u64;
                s.user_data = id;
                self.ring.push();
            }
            REN_OP_CLOSE => {
                let fd = u.fd;
                if self.fdcount.contains_key(&fd) {
                    self.async_cancel(fd, 0, k::IORING_ASYNC_CANCEL_FD | k::IORING_ASYNC_CANCEL_ALL);
                    self.closing.push((fd, id));
                } else {
                    self.poisoned.remove(&fd);
                    let r = if libc::close(fd) < 0 { -(errno() as i64) } else { 0 };
                    d.reply(c, w, id, REN_DONE, res1(r), &[]);
                }
            }
            _ => {
                d.reply(c, w, id, REN_DONE, res1(-(libc::ENOSYS as i64)), &[]);
            }
        }
    }

    fn inflight(&self) -> usize {
        self.ops.len() + self.closing.len()
    }

    unsafe fn cancel_all(&mut self, _d: &Drv, _c: *mut ren_core, _w: i32) {
        if !self.cancel_all_sent {
            self.cancel_all_sent = true;
            for &id in self.ops.keys().collect::<Vec<_>>() {
                let s = self.ring.sqe();
                s.opcode = opc::IORING_OP_ASYNC_CANCEL as u8;
                s.fd = -1;
                s.__bindgen_anon_2.addr = id;
                s.user_data = CANCEL_UD;
                self.ring.push();
            }
        }
    }

    unsafe fn wait(&mut self, d: &Drv, c: *mut ren_core, w: i32, block: bool) {
        let e = self.ring.enter(if block { 1 } else { 0 }, true);
        let mut cq = core::mem::take(&mut self.cq);
        self.ring.reap(&mut cq);
        if e != 0 && cq.is_empty() && e != libc::EBUSY && e != libc::EAGAIN {
            d.set_err("io_uring_enter failed");
        }
        for &(ud, res) in cq.iter() {
            self.cqe(d, c, w, ud, res);
        }
        cq.clear();
        self.cq = cq;
    }

    unsafe fn teardown(&mut self) {
        self.ring.close();
    }
}

impl Drop for UrW {
    fn drop(&mut self) {
        // SAFETY: the ring is ours; close is idempotent.
        unsafe { self.ring.close() }
    }
}
