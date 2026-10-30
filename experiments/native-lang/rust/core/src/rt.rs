//! The runtime around the crate: in no_std builds, a global allocator over
//! libc malloc and a panic handler that aborts. Also tiny libc helpers.
#![allow(dead_code)]

/// Write a message to stderr (no allocation, no std).
pub fn eprint(s: &[u8]) {
    let mut p = s;
    while !p.is_empty() {
        // SAFETY: p is a valid byte slice; write(2) reads at most p.len() bytes.
        let n = unsafe { libc::write(2, p.as_ptr().cast(), p.len()) };
        if n <= 0 {
            return;
        }
        p = &p[n as usize..];
    }
}

pub fn die(s: &str) -> ! {
    eprint(b"ren_core (rust): ");
    eprint(s.as_bytes());
    eprint(b"\n");
    // SAFETY: abort(3) has no preconditions.
    unsafe { libc::abort() }
}

#[cfg(all(not(feature = "std"), not(test)))]
mod nostd {
    use core::alloc::{GlobalAlloc, Layout};

    struct Malloc;
    // SAFETY: malloc/free/realloc and aligned_alloc follow GlobalAlloc's
    // contract for the sizes and alignments asked for.
    unsafe impl GlobalAlloc for Malloc {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            if l.align() <= 16 {
                libc::malloc(l.size()).cast()
            } else {
                let size = l.size().div_ceil(l.align()) * l.align();
                libc::aligned_alloc(l.align(), size).cast()
            }
        }
        unsafe fn dealloc(&self, p: *mut u8, _l: Layout) {
            libc::free(p.cast())
        }
        unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
            if l.align() <= 16 {
                libc::realloc(p.cast(), new).cast()
            } else {
                let n = self.alloc(Layout::from_size_align_unchecked(new, l.align()));
                if !n.is_null() {
                    core::ptr::copy_nonoverlapping(p, n, core::cmp::min(l.size(), new));
                    self.dealloc(p, l);
                }
                n
            }
        }
    }
    #[global_allocator]
    static A: Malloc = Malloc;

    /// The precompiled `alloc` of stable Rust is built with panic=unwind and
    /// references this symbol (undefined reference at link time otherwise:
    /// found on cloud). With panic=abort nothing unwinds, so it is never
    /// called; `#[lang = "eh_personality"]` would be the proper fix but is
    /// nightly-only.
    #[no_mangle]
    extern "C" fn rust_eh_personality() {}

    struct Buf {
        b: [u8; 512],
        n: usize,
    }
    impl core::fmt::Write for Buf {
        fn write_str(&mut self, s: &str) -> core::fmt::Result {
            let k = core::cmp::min(s.len(), self.b.len() - self.n);
            self.b[self.n..self.n + k].copy_from_slice(&s.as_bytes()[..k]);
            self.n += k;
            Ok(())
        }
    }
    #[panic_handler]
    fn panic(info: &core::panic::PanicInfo) -> ! {
        use core::fmt::Write;
        let mut b = Buf { b: [0; 512], n: 0 };
        let _ = write!(b, "ren_core (rust, no_std): panic: {}\n", info);
        super::eprint(&b.b[..b.n]);
        // SAFETY: abort(3) has no preconditions.
        unsafe { libc::abort() }
    }
}
