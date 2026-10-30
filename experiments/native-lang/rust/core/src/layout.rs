//! ren_layout_table (SPEC §0.3): every REN_LAYOUT_LIST name with the value
//! the bindgen types give it. layout_check compares it with C's view.
use crate::sys::*;

pub struct Table(pub [ren_layout_ent; N]);
// SAFETY: the names are 'static C string literals, never written.
unsafe impl Sync for Table {}

include!(concat!(env!("OUT_DIR"), "/layout_gen.rs"));

#[no_mangle]
pub unsafe extern "C" fn ren_layout_table(out: *mut *const ren_layout_ent) -> usize {
    if !out.is_null() {
        *out = TABLE.0.as_ptr();
    }
    N
}
