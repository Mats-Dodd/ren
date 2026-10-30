// Shared by core/build.rs and hot/build.rs (include!d): run the bindgen
// CLI (0.66.1) on $REN_HARNESS/slice.h into OUT_DIR/slice.rs. SPEC §0.2:
// layouts come from slice.h only; nothing here restates one.
use std::path::PathBuf;
use std::process::Command;

fn harness_dir() -> PathBuf {
    println!("cargo:rerun-if-env-changed=REN_HARNESS");
    match std::env::var_os("REN_HARNESS") {
        Some(h) => PathBuf::from(h),
        None => PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../harness"),
    }
}

fn bindgen(header: &std::path::Path, out: &std::path::Path, extra: &[&str]) {
    println!("cargo:rerun-if-changed={}", header.display());
    println!("cargo:rerun-if-env-changed=LIBCLANG_PATH");
    // bindgen 0.66.1 loads the newest libclang it finds. With libclang-22
    // installed (for cross-language LTO) it silently turns every struct
    // declared through `typedef struct X X;` before its body into an
    // opaque `{ _address: u8 }` (found on cloud, 2026-10-30). libclang-18
    // (the system clang) translates slice.h correctly, so pin it unless
    // the caller chose one.
    let libclang = std::env::var("LIBCLANG_PATH").unwrap_or_else(|_| "/usr/lib/llvm-18/lib".into());
    let st = Command::new("bindgen")
        .env("LIBCLANG_PATH", &libclang)
        .args(["--use-core", "--ctypes-prefix", "core::ffi", "--no-layout-tests"])
        .args(extra)
        .arg(header)
        .arg("-o")
        .arg(out)
        .status()
        .expect("bindgen CLI not found (bindgen 0.66.1 expected on PATH)");
    assert!(st.success(), "bindgen failed on {}", header.display());
}

fn slice_bindings() {
    let h = harness_dir().join("slice.h");
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("slice.rs");
    bindgen(&h, &out, &[]);
    let text = std::fs::read_to_string(&out).unwrap();
    // A struct bindgen could not lay out comes back opaque; fail the build
    // rather than let a {_address: u8} through.
    for s in ["ren_task", "ren_obj", "ren_call", "ren_io_body", "ren_await", "ren_config", "ren_host"] {
        let opaque = format!("pub struct {s} {{\n    pub _address: u8,\n}}");
        assert!(!text.contains(&opaque), "bindgen produced an opaque {s}: wrong libclang? (LIBCLANG_PATH={:?})",
                std::env::var("LIBCLANG_PATH").ok());
    }
}

/// REN_LAYOUT_LIST from slice.h, turned into Rust table entries whose
/// values come from the bindgen types (offset_of!/size_of). The list of
/// names is read from the header, so it follows slice.h too.
#[allow(dead_code)]
fn layout_list() {
    let h = harness_dir().join("slice.h");
    let src = std::fs::read_to_string(&h).unwrap();
    let start = src.find("#define REN_LAYOUT_LIST(X, S)").expect("REN_LAYOUT_LIST not in slice.h");
    let mut body = String::new();
    for line in src[start..].lines() {
        body.push_str(line);
        body.push(' ');
        if !line.trim_end().ends_with('\\') {
            break;
        }
    }
    let body = &body["#define REN_LAYOUT_LIST(X, S)".len()..];
    let mut out = String::from("[\n");
    let mut n = 0;
    let b = body.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if (b[i] == b'X' || b[i] == b'S') && i + 1 < b.len() && b[i + 1] == b'(' && (i == 0 || !b[i - 1].is_ascii_alphanumeric()) {
            let close = body[i..].find(')').unwrap() + i;
            let args: Vec<&str> = body[i + 2..close].split(',').map(|s| s.trim()).collect();
            if b[i] == b'X' {
                out += &format!(
                    "    ren_layout_ent {{ name: c\"{0}.{1}\".as_ptr(), value: ::core::mem::offset_of!({0}, {1}) as u32, _pad: 0 }},\n",
                    args[0], args[1]
                );
            } else {
                out += &format!(
                    "    ren_layout_ent {{ name: c\"sizeof({0})\".as_ptr(), value: ::core::mem::size_of::<{0}>() as u32, _pad: 0 }},\n",
                    args[0]
                );
            }
            n += 1;
            i = close + 1;
        } else {
            i += 1;
        }
    }
    out += "]\n";
    assert!(n > 10, "parsed only {n} REN_LAYOUT_LIST entries");
    let o = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("layout_gen.rs");
    std::fs::write(o, format!("// generated from slice.h's REN_LAYOUT_LIST ({n} names)\npub const N: usize = {n};\npub static TABLE: Table = Table({out});\n")).unwrap();
}
