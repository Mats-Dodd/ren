include!("../tools/bindgen_slice.rs");

fn main() {
    slice_bindings();
    layout_list();
    // The kernel's io_uring ABI, also generated (never hand-mirrored).
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("uring.rs");
    bindgen(
        std::path::Path::new("/usr/include/linux/io_uring.h"),
        &out,
        &[
            "--allowlist-type", "io_uring_(sqe|cqe|params|op|getevents_arg)|io_sqring_offsets|io_cqring_offsets|__kernel_timespec",
            "--allowlist-var", "IORING_.*|IOSQE_.*",
            "--constified-enum-module", "io_uring_op",
        ],
    );
}
