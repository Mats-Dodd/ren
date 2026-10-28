// The slices benchmark's Rust twin (research/slices.md): each parser
// with `&[u8]` slices, which borrow the input, and with offsets into it.
// `main [n] [rounds] [kernel]`, the kernel `all`, or one of `logs`,
// `logs_r`, `json`, `json_r`, `pages`, `pages_r`, which prints its
// input's size and its checksum. Std only, no unsafe.
use std::env;
use std::hint::black_box;

// ---- the inputs, byte for byte gen.ren's ----

fn next(seed: &mut i64) -> i64 {
    *seed = (*seed * 1103515245 + 12345) % 2147483648;
    *seed
}

fn push_int(out: &mut Vec<u8>, n: i64) {
    if n >= 10 {
        push_int(out, n / 10);
    }
    out.push(b'0' + (n % 10) as u8);
}

fn logs_input(lines: i64) -> Vec<u8> {
    let mut seed = 42;
    let mut out = Vec::new();
    let levels = ["ERROR", "WARN", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO", "INFO"];
    let services = ["auth", "billing", "search", "cart"];
    let resources = ["users", "orders", "items", "carts", "sessions"];
    for i in 0..lines {
        push_int(&mut out, 1700000000 + i);
        out.push(b' ');
        out.extend_from_slice(levels[(next(&mut seed) % 10) as usize].as_bytes());
        out.push(b' ');
        out.extend_from_slice(services[(next(&mut seed) % 4) as usize].as_bytes());
        out.push(b' ');
        push_int(&mut out, next(&mut seed) % 5000);
        out.push(b' ');
        out.extend_from_slice(b"/api/v");
        push_int(&mut out, next(&mut seed) % 3);
        out.push(b'/');
        out.extend_from_slice(resources[(next(&mut seed) % 5) as usize].as_bytes());
        out.push(b'/');
        push_int(&mut out, next(&mut seed) % 100000);
        out.push(b'\n');
    }
    out
}

fn key(out: &mut Vec<u8>, k: &str) {
    out.push(b'"');
    out.extend_from_slice(k.as_bytes());
    out.extend_from_slice(b"\":");
}

fn json_input(n: i64) -> Vec<u8> {
    let mut seed = 7;
    let mut out = Vec::new();
    let tags = ["red", "green", "blue", "admin", "beta", "x"];
    out.push(b'[');
    for i in 0..n {
        if i > 0 { out.extend_from_slice(b",\n"); }
        out.push(b'{');
        key(&mut out, "id"); push_int(&mut out, i); out.push(b',');
        key(&mut out, "name"); out.extend_from_slice(b"\"user_"); push_int(&mut out, next(&mut seed) % 100000); out.push(b'"'); out.push(b',');
        key(&mut out, "email"); out.extend_from_slice(b"\"u"); push_int(&mut out, next(&mut seed) % 100000); out.extend_from_slice(b"@example.com\",");
        key(&mut out, "tags"); out.push(b'[');
        let k = next(&mut seed) % 4;
        for t in 0..k {
            if t > 0 { out.push(b','); }
            out.push(b'"'); out.extend_from_slice(tags[(next(&mut seed) % 6) as usize].as_bytes()); out.push(b'"');
        }
        out.push(b']'); out.push(b',');
        key(&mut out, "score"); push_int(&mut out, next(&mut seed) % 10000); out.push(b',');
        key(&mut out, "active");
        out.extend_from_slice(if next(&mut seed) % 2 == 0 { b"true" } else { b"false" });
        out.push(b'}');
    }
    out.push(b']');
    out
}

fn digits(n: i64) -> i64 { if n < 10 { 1 } else { 1 + digits(n / 10) } }

fn pages_input(count: i64) -> Vec<u8> {
    let mut seed = 3;
    let mut out = Vec::new();
    let mut id = 0i64;
    for _ in 0..count {
        let (mut keys, mut lens) = (Vec::new(), Vec::new());
        let mut used = 2;
        loop {
            let k = next(&mut seed) % 1000000;
            let v = 8 + next(&mut seed) % 120;
            let size = 2 + 1 + 1 + digits(k) + 2 + v;
            if used + size > 4096 { break }
            keys.push(k); lens.push(v); used += size;
        }
        let n = keys.len() as i64;
        out.push((n % 256) as u8); out.push((n / 256) as u8);
        let mut off = 2 + 2 * n;
        for r in 0..keys.len() {
            out.push((off % 256) as u8); out.push((off / 256) as u8);
            off += 1 + 1 + digits(keys[r]) + 2 + lens[r];
        }
        for r in 0..keys.len() {
            out.push((1 + digits(keys[r])) as u8);
            out.push(b'k');
            push_int(&mut out, keys[r]);
            out.push((lens[r] % 256) as u8); out.push((lens[r] / 256) as u8);
            for i in 0..lens[r] { out.push((97 + (id + i) % 26) as u8) }
            id += 1;
        }
        for _ in off..4096 { out.push(0) }
    }
    out
}

// ---- (a) log lines, split into fields ----

#[derive(Default)]
struct Stats { errors: i64, warns: i64, error_latency: i64, path_bytes: i64, search: i64 }

fn total(st: &Stats) -> i64 {
    st.errors + st.warns * 3 + st.error_latency + st.path_bytes * 7 + st.search * 11
}

fn parse_int(b: &[u8]) -> i64 {
    let mut n: i64 = 0;
    for &c in b { n = n * 10 + c as i64 - 48; }
    n
}

fn line(l: &[u8], st: &mut Stats) {
    let mut is_error = false;
    for (f, field) in l.split(|&c| c == b' ').enumerate() {
        match f {
            1 => if field == b"ERROR" { st.errors += 1; is_error = true } else if field == b"WARN" { st.warns += 1 },
            2 => if field == b"search" { st.search += 1 },
            3 => if is_error { st.error_latency += parse_int(field) },
            4 => st.path_bytes += field.len() as i64,
            _ => {}
        }
    }
}

fn logs(buf: &[u8]) -> i64 {
    let mut st = Stats::default();
    let mut i = 0;
    for j in 0..buf.len() {
        if buf[j] == b'\n' { line(&buf[i..j], &mut st); i = j + 1; }
    }
    total(&st)
}

// each field a range of the buffer, indexed with checks as Ren's are
fn line_r(b: &[u8], from: usize, to: usize, st: &mut Stats) {
    let mut start = from;
    let mut f = 0;
    let mut is_error = false;
    for k in from..=to {
        if k == to || b[k] == b' ' {
            let eq = |s: &[u8]| k - start == s.len() && (0..s.len()).all(|i| b[start + i] == s[i]);
            match f {
                1 => if eq(b"ERROR") { st.errors += 1; is_error = true } else if eq(b"WARN") { st.warns += 1 },
                2 => if eq(b"search") { st.search += 1 },
                3 => if is_error { let mut n = 0i64; for i in start..k { n = n * 10 + b[i] as i64 - 48 } st.error_latency += n },
                4 => st.path_bytes += (k - start) as i64,
                _ => {}
            }
            f += 1;
            start = k + 1;
        }
    }
}

fn logs_r(buf: &[u8]) -> i64 {
    let mut st = Stats::default();
    let mut i = 0;
    for j in 0..buf.len() {
        if buf[j] == b'\n' { line_r(buf, i, j, &mut st); i = j + 1; }
    }
    total(&st)
}

// ---- (b) a JSON-ish tokenizer, its tokens kept, then walked ----

fn punct(c: u8) -> u8 {
    match c { b'{' => 1, b'}' => 2, b'[' => 3, b']' => 4, b':' => 5, b',' => 6, _ => 0 }
}
fn space(c: u8) -> bool { c == b' ' || c == b'\n' || c == b'\t' || c == b'\r' }

// the scan, shared: calls [emit] with each token's kind and range
#[inline(always)]
fn scan(b: &[u8], mut emit: impl FnMut(u8, usize, usize)) {
    let n = b.len();
    let mut i = 0;
    while i < n {
        let c = b[i];
        let p = punct(c);
        if p > 0 { emit(p, i, i + 1); i += 1 }
        else if c == b'"' { let mut j = i + 1; while b[j] != b'"' { j += 1 } emit(7, i + 1, j); i = j + 1 }
        else if c == b't' { emit(9, i, i + 4); i += 4 }
        else if c == b'f' { emit(10, i, i + 5); i += 5 }
        else if space(c) { i += 1 }
        else { let mut j = i; while j < n && b[j] >= b'0' && b[j] <= b'9' { j += 1 } emit(8, i, j); i = j }
    }
}

struct Tok<'a> { kind: u8, text: &'a [u8] }

fn walk(toks: &[Tok]) -> i64 {
    let (mut score, mut names, mut tag_bytes, mut trues, mut in_tags) = (0i64, 0i64, 0i64, 0i64, false);
    for i in 0..toks.len() - 2 {
        let t = &toks[i];
        if t.kind == 7 && toks[i + 1].kind == 5 {
            let v = &toks[i + 2];
            if t.text == b"score" { score += parse_int(v.text) }
            else if t.text == b"name" { names += 1 }
            else if t.text == b"tags" { in_tags = true }
            else if t.text == b"active" && v.kind == 9 { trues += 1 }
        } else if in_tags && t.kind == 7 { tag_bytes += t.text.len() as i64 }
        else if t.kind == 4 { in_tags = false }
    }
    score + names * 3 + tag_bytes * 7 + trues * 11 + toks.len() as i64 * 13
}

fn json(b: &[u8]) -> i64 {
    let mut toks = Vec::new();
    scan(b, |k, i, j| toks.push(Tok { kind: k, text: &b[i..j] }));
    walk(&toks)
}

#[derive(Clone, Copy)]
struct T { kind: u8, start: u32, stop: u32 }

fn walk_r(b: &[u8], toks: &[T]) -> i64 {
    let (mut score, mut names, mut tag_bytes, mut trues, mut in_tags) = (0i64, 0i64, 0i64, 0i64, false);
    let s = |t: &T| &b[t.start as usize..t.stop as usize];
    for i in 0..toks.len() - 2 {
        let t = &toks[i];
        if t.kind == 7 && toks[i + 1].kind == 5 {
            let v = &toks[i + 2];
            if s(t) == b"score" { score += parse_int(s(v)) }
            else if s(t) == b"name" { names += 1 }
            else if s(t) == b"tags" { in_tags = true }
            else if s(t) == b"active" && v.kind == 9 { trues += 1 }
        } else if in_tags && t.kind == 7 { tag_bytes += (t.stop - t.start) as i64 }
        else if t.kind == 4 { in_tags = false }
    }
    score + names * 3 + tag_bytes * 7 + trues * 11 + toks.len() as i64 * 13
}

fn json_r(b: &[u8]) -> i64 {
    let mut toks = Vec::new();
    scan(b, |k, i, j| toks.push(T { kind: k, start: i as u32, stop: j as u32 }));
    walk_r(b, &toks)
}

// ---- (c) pages parsed into records, kept, then queried ----

fn u16_at(b: &[u8], i: usize) -> usize { b[i] as usize + 256 * b[i + 1] as usize }

struct Rec<'a> { key: &'a [u8], value: &'a [u8] }

fn pages(b: &[u8]) -> i64 {
    let mut recs = Vec::new();
    for p in 0..b.len() / 4096 {
        let base = p * 4096;
        for r in 0..u16_at(b, base) {
            let at = base + u16_at(b, base + 2 + 2 * r);
            let klen = b[at] as usize;
            let vat = at + 1 + klen;
            let vlen = u16_at(b, vat);
            recs.push(Rec { key: &b[at + 1..vat], value: &b[vat + 2..vat + 2 + vlen] });
        }
    }
    let (mut k1, mut sevens, mut vowels) = (0i64, 0i64, 0i64);
    for r in &recs {
        if r.key[1] == b'1' { k1 += 1 }
        if r.key[r.key.len() - 1] == b'7' { sevens += r.value.len() as i64 }
        if r.value[0] == b'a' { vowels += 1 }
    }
    k1 + sevens * 3 + vowels * 7 + recs.len() as i64 * 11
}

#[derive(Clone, Copy)]
struct RecR { key: u32, klen: u16, value: u32, vlen: u16 }

fn pages_r(b: &[u8]) -> i64 {
    let mut recs = Vec::new();
    for p in 0..b.len() / 4096 {
        let base = p * 4096;
        for r in 0..u16_at(b, base) {
            let at = base + u16_at(b, base + 2 + 2 * r);
            let klen = b[at] as usize;
            let vat = at + 1 + klen;
            recs.push(RecR { key: (at + 1) as u32, klen: klen as u16, value: (vat + 2) as u32, vlen: u16_at(b, vat) as u16 });
        }
    }
    let (mut k1, mut sevens, mut vowels) = (0i64, 0i64, 0i64);
    for r in &recs {
        if b[r.key as usize + 1] == b'1' { k1 += 1 }
        if b[r.key as usize + r.klen as usize - 1] == b'7' { sevens += r.vlen as i64 }
        if b[r.value as usize] == b'a' { vowels += 1 }
    }
    k1 + sevens * 3 + vowels * 7 + recs.len() as i64 * 11
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let n: i64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(200000);
    let rounds: i64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(20);
    let kernel = args.get(3).map(|s| s.as_str()).unwrap_or("all");
    let input = |k: &str| -> Vec<u8> {
        match k {
            "logs" => logs_input(n),
            "json" => json_input(n / 2),
            _ => pages_input(n / 50),
        }
    };
    let run = |f: fn(&[u8]) -> i64, b: &[u8]| -> i64 {
        let mut x = 0;
        for _ in 0..rounds { x += f(black_box(b)); }
        x
    };
    let all: [(&str, fn(&[u8]) -> i64, fn(&[u8]) -> i64); 3] = [
        ("logs", logs, logs_r),
        ("json", json, json_r),
        ("pages", pages, pages_r),
    ];
    for (name, f, g) in all {
        if kernel == "all" {
            let b = input(name);
            println!("{}", b.len());
            println!("{}", run(f, &b));
            println!("{}", run(g, &b));
        } else if kernel == name || kernel.strip_suffix("_r") == Some(name) {
            let b = input(name);
            println!("{}", b.len());
            println!("{}", run(if kernel == name { f } else { g }, &b));
        }
    }
}
