// The strings benchmark's Rust twin (bench.ren says what each workload
// is): research/strings/track-b's workloads, their inputs made in
// process, byte for byte what track-b/c/gen.c writes and what gen.ren
// makes. `main <workload> <n> <rounds>`, the workload one of tok, sort,
// map, map_std, group, group_std, logs, out_json, out_logs, utf8_ascii,
// utf8_cjk, utf8_mixed, which prints its input's size and then each
// round's check; or `main dump <n> <dir>`, which writes gen.c's files at
// size [n] into [dir], to compare with gen.c's own. Slices are `&str`s
// of the input, which borrow it; `map` and `group` hash with FxHash,
// written here, and `map_std` and `group_std` with std's SipHash;
// output is built with `String::push_str`; `from_utf8` is std's. Std
// only, no unsafe, one thread.
use std::collections::HashMap;
use std::convert::TryInto;
use std::env;
use std::fmt::Write as _;
use std::hash::{BuildHasher, BuildHasherDefault, Hasher};
use std::hint::black_box;

// ---- FxHash: rustc's hasher (rustc-hash 1's), a multiply and a rotate a word ----

#[derive(Default)]
struct Fx(u64);

impl Hasher for Fx {
    fn write(&mut self, bytes: &[u8]) {
        let mut c = bytes.chunks_exact(8);
        for w in &mut c {
            self.add(u64::from_le_bytes(w.try_into().unwrap()));
        }
        let r = c.remainder();
        let mut i = 0;
        if r.len() - i >= 4 {
            self.add(u32::from_le_bytes(r[i..i + 4].try_into().unwrap()) as u64);
            i += 4;
        }
        if r.len() - i >= 2 {
            self.add(u16::from_le_bytes(r[i..i + 2].try_into().unwrap()) as u64);
            i += 2;
        }
        if r.len() - i >= 1 {
            self.add(r[i] as u64);
        }
    }
    fn write_u8(&mut self, x: u8) {
        self.add(x as u64);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}

impl Fx {
    fn add(&mut self, w: u64) {
        self.0 = (self.0.rotate_left(5) ^ w).wrapping_mul(0x517cc1b727220a95);
    }
}

type FxBuild = BuildHasherDefault<Fx>;

// ---- the inputs: gen.c's, each from the generator's state where gen.c starts it ----

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
    fn r(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    fn p(&mut self, pct: u64) -> bool {
        self.r(100) < pct
    }
}

// where gen.c's generator is when it starts each file
const TOK: u64 = 2685821657736338717;
const KEYS: u64 = 1501143529475956227;
const SORT: u64 = 11280350821882103235;
const ROWS: u64 = 3516444820516554288;
const LOGS: u64 = 12666297937331212984;
const PEOPLE: u64 = 3851254842298927852;

const W: [&str; 64] = [
    "user", "id", "get", "set", "count", "item", "list", "map", "node", "value", "buf", "len",
    "next", "prev", "data", "key", "index", "name", "path", "time", "size", "read", "write",
    "parse", "token", "state", "error", "result", "config", "server", "client", "request",
    "response", "handler", "cache", "queue", "event", "stream", "frame", "table", "pool",
    "array", "bytes", "string", "order", "account", "price", "total", "line", "file", "entry",
    "temp", "flag", "mode", "kind", "type", "ref", "ptr", "ctx", "cur", "pos", "off", "max",
    "min",
];
const KW: [&str; 10] = ["let", "fn", "if", "else", "return", "for", "in", "match", "var", "while"];
const SYL: [&str; 28] = [
    "san", "por", "ber", "lin", "mad", "rid", "tok", "yo", "lon", "don", "par", "is", "osa",
    "ka", "new", "york", "chi", "ca", "go", "sao", "pau", "lo", "rio", "mel", "bour", "ne", "syd",
    "ney",
];

fn word(g: &mut Rng) -> &'static str {
    W[g.r(64) as usize]
}

fn ident(g: &mut Rng) -> String {
    let parts = 1 + g.r(3);
    let mut o = String::new();
    for i in 0..parts {
        if i > 0 {
            o.push('_');
        }
        o.push_str(word(g));
    }
    if g.p(20) {
        write!(o, "{}", g.r(100)).unwrap();
    }
    o
}

fn key(g: &mut Rng, kind: u64) -> String {
    if kind < 60 {
        ident(g)
    } else if kind < 85 {
        let w = word(g);
        let a = ident(g);
        let b = ident(g);
        format!("{}.{}.{}", w, a, b)
    } else {
        let v = 1 + g.r(2);
        let w = word(g);
        let id = g.r(1000000);
        let a = ident(g);
        let page = g.r(50);
        format!("https://api.example.com/v{}/{}/{}/{}?page={}", v, w, id, a, page)
    }
}

// code-like statements, [n] tokens or a few more
fn tok_input(n: i64) -> String {
    let mut g = Rng(TOK);
    let mut f = String::new();
    let mut toks = 0;
    let lit = ["hello, world", "café au lait", "日本語", "a longer string literal with several words in it", "ok"];
    while toks < n {
        let form = g.r(4);
        if form == 0 {
            // gen.c prints its first `ident(a)` after the second has
            // overwritten it, so both are the second
            let _ = ident(&mut g);
            let b = ident(&mut g);
            let k = ident(&mut g);
            let x = g.r(100000);
            let a = ident(&mut g);
            write!(f, "let {} = {}({}, {}) + {};\n", a, b, k, x, a).unwrap();
            toks += 12;
        } else if form == 1 {
            let a = ident(&mut g);
            let b = ident(&mut g);
            let x = g.r(1000);
            let k = ident(&mut g);
            write!(f, "if {}.{} >= {} {{\n  return {};\n}}\n", a, b, x, k).unwrap();
            toks += 11;
        } else if form == 2 {
            let a = ident(&mut g);
            let l = lit[g.r(5) as usize];
            write!(f, "{} += \"{}\";\n", a, l).unwrap();
            toks += 4;
        } else {
            let kw = KW[g.r(10) as usize];
            let a = ident(&mut g);
            let b = ident(&mut g);
            let k = ident(&mut g);
            write!(f, "{} {} = {} -> {};\n", kw, a, b, k).unwrap();
            toks += 6;
        }
    }
    f
}

// [lines] keys drawn from a pool of [pool], 80% from its hottest tenth
fn keys_input(pool: i64, lines: i64) -> String {
    let mut g = Rng(KEYS);
    let mut ks = Vec::new();
    for _ in 0..pool {
        let kind = g.r(100);
        ks.push(key(&mut g, kind));
    }
    let mut f = String::new();
    for _ in 0..lines {
        let j = if g.p(80) { g.r(pool as u64 / 10) } else { g.r(pool as u64) };
        f.push_str(&ks[j as usize]);
        f.push('\n');
    }
    f
}

fn sort_input(n: i64) -> String {
    let mut g = Rng(SORT);
    let mut f = String::new();
    for _ in 0..n {
        let kind = g.r(100);
        f.push_str(&key(&mut g, kind));
        f.push('\n');
    }
    f
}

// [rows] rows of a city of [cities], a department and an amount
fn rows_input(cities: i64, rows: i64) -> String {
    let mut g = Rng(ROWS);
    let mut cs = Vec::new();
    for i in 0..cities {
        let mut a = String::new();
        let n = 2 + g.r(4);
        for j in 0..n {
            a.push_str(SYL[g.r(28) as usize]);
            if j == 1 && g.p(40) {
                a.push(' ');
            }
        }
        a = a[..1].to_uppercase() + &a[1..];
        if g.p(5) {
            a.push_str(" é");
        }
        cs.push(format!("{}{}", a, i % 7));
    }
    let mut f = String::new();
    for _ in 0..rows {
        let c = &cs[g.r(cities as u64) as usize];
        let d = W[g.r(20) as usize];
        let x = g.r(100000);
        write!(f, "{},{},{}\n", c, d, x).unwrap();
    }
    f
}

fn logs_input(lines: i64) -> String {
    let mut g = Rng(LOGS);
    let svc = ["api-gateway", "auth", "billing", "search", "orders", "inventory", "notify", "users"];
    let lv = ["INFO", "WARN", "ERROR", "DEBUG"];
    let meth = ["GET", "POST", "PUT", "DELETE"];
    let mut f = String::new();
    for _ in 0..lines {
        let r = g.r(100);
        let l = if r < 85 { 0 } else if r < 95 { 1 } else if r < 99 { 2 } else { 3 };
        let pk = g.r(5);
        let path = match pk {
            0 => format!("/v1/users/{}/orders", g.r(100000)),
            1 => format!("/v2/items/{}", g.r(1000000)),
            2 => "/health".to_string(),
            3 => format!("/v1/search?q={}", word(&mut g)),
            _ => format!("/v1/users/{}", g.r(100000)),
        };
        let status = if g.p(2) { 500 } else if g.p(5) { 404 } else { 200 };
        let (mm, ss, ms) = (g.r(60), g.r(60), g.r(1000));
        let s = svc[g.r(8) as usize];
        let m = meth[g.r(4) as usize];
        let dur = 1 + g.r(2000);
        let req = g.next();
        write!(
            f,
            "2026-10-29T09:{:02}:{:02}.{:03}Z {} {} {} {} {} {}ms req_id={:016x}\n",
            mm, ss, ms, lv[l], s, m, path, status, dur, req
        )
        .unwrap();
    }
    f
}

// id, name, email, score and 0 to 3 tags, tab-separated
fn people_input(n: i64) -> String {
    let mut g = Rng(PEOPLE);
    let mut f = String::new();
    for i in 0..n {
        let a = word(&mut g);
        let b = word(&mut g);
        let mut nm = format!("{} {}", a, b);
        nm = nm[..1].to_uppercase() + &nm[1..];
        if g.p(3) {
            nm.push_str(" \"jr\"");
        }
        if g.p(5) {
            nm.push_str(" Muñoz");
        }
        let (e1, e2, e3, score) = (word(&mut g), word(&mut g), g.r(1000), g.r(1000000));
        write!(f, "{}\t{}\t{}.{}{}@example.com\t{}\t", i, nm, e1, e2, e3, score).unwrap();
        let nt = g.r(4);
        for t in 0..nt {
            if t > 0 {
                f.push(';');
            }
            f.push_str(word(&mut g));
        }
        f.push('\n');
    }
    f
}

// track-b/c/b5.c's text of [kind], [n] bytes, ending on a character
fn utf8_input(kind: &str, n: i64) -> Vec<u8> {
    let mut g = Rng(42);
    let mut o = String::new();
    while (o.len() as i64) < n - 4 {
        let r = g.next() % 100;
        let c = if r == 99 && g.next() & 1 == 1 {
            '\n' as u32
        } else if kind == "ascii" {
            if r < 15 { ' ' as u32 } else { 'a' as u32 + (g.next() % 26) as u32 }
        } else if kind == "cjk" {
            if r < 10 { ' ' as u32 } else { 0x4e00 + (g.next() % 20000) as u32 }
        } else if r < 98 {
            if r < 15 { ' ' as u32 } else { 'a' as u32 + (g.next() % 26) as u32 }
        } else if r < 99 {
            0xe9
        } else {
            0x65e5
        };
        o.push(char::from_u32(c).unwrap());
    }
    while (o.len() as i64) < n {
        o.push(' ');
    }
    o.into_bytes()
}

// ---- the kernels, each giving its check ----

fn tok(src: &str) -> String {
    let p = src.as_bytes();
    let n = p.len();
    let mut ts: Vec<(i64, &str)> = Vec::new();
    let mut i = 0;
    while i < n {
        let c = p[i];
        if c == b' ' || c == b'\n' || c == b'\t' {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        let kind;
        if c == b'_' || c.is_ascii_alphabetic() {
            while j < n && (p[j] == b'_' || p[j].is_ascii_alphanumeric()) {
                j += 1;
            }
            kind = 0;
        } else if c.is_ascii_digit() {
            while j < n && p[j].is_ascii_digit() {
                j += 1;
            }
            kind = 1;
        } else if c == b'"' {
            while j < n && p[j] != b'"' {
                j += 1;
            }
            j += 1;
            kind = 2;
        } else {
            if j < n
                && ((matches!(c, b'=' | b'!' | b'<' | b'>' | b'+') && p[j] == b'=')
                    || (c == b'-' && p[j] == b'>'))
            {
                j += 1;
            }
            kind = 3;
        }
        ts.push((kind, &src[i..j]));
        i = j;
    }
    let (mut returns, mut idents, mut total) = (0, 0, 0);
    for (kind, text) in &ts {
        returns += (*text == "return") as i64;
        idents += (*kind == 0) as i64;
        total += text.len();
    }
    format!("{},{},{},{}", ts.len(), returns, idents, total)
}

fn map<S: BuildHasher + Default>(src: &str) -> String {
    let mut m: HashMap<&str, i64, S> = HashMap::default();
    for k in src.lines() {
        *m.entry(k).or_insert(0) += 1;
    }
    let mut sum = 0;
    for k in src.lines() {
        sum += m[k];
    }
    format!("{},{}", m.len(), sum)
}

fn sort(src: &str) -> String {
    let mut xs: Vec<&str> = src.lines().collect();
    xs.sort_unstable();
    let mut check: i64 = 0;
    for k in (0..xs.len()).step_by(1000) {
        check += xs[k].len() as i64 * k as i64 + xs[k].as_bytes()[0] as i64;
    }
    format!("{},{}", xs.len(), check)
}

fn group<S: BuildHasher + Default>(src: &str) -> String {
    let mut m: HashMap<&str, i64, S> = HashMap::default();
    for l in src.lines() {
        let c1 = l.find(',').unwrap();
        let k = l.rfind(',').unwrap() + 1;
        let mut amt = 0;
        for &d in &l.as_bytes()[k..] {
            amt = amt * 10 + (d - b'0') as i64;
        }
        *m.entry(&l[..c1]).or_insert(0) += amt;
    }
    let (mut check, mut total) = (0i64, 0i64);
    for (k, v) in &m {
        check ^= k.len() as i64 * 1000003 + v;
        total += v;
    }
    format!("{},{},{}", m.len(), total, check)
}

struct Rec<'a> {
    ts: &'a str,
    level: &'a str,
    svc: &'a str,
    method: &'a str,
    path: &'a str,
    req: &'a str,
    status: i64,
    dur: i64,
}

fn digits(s: &str) -> i64 {
    s.bytes().fold(0, |n, d| n * 10 + (d - b'0') as i64)
}

fn records(src: &str) -> Vec<Rec<'_>> {
    let mut rs: Vec<Rec> = Vec::new();
    for l in src.lines() {
        let mut f = l.splitn(8, ' ');
        let mut next = || f.next().unwrap();
        let (ts, level, svc, method, path) = (next(), next(), next(), next(), next());
        let status = digits(next());
        let d = next();
        let dur = digits(&d[..d.len() - 2]);
        let req = &next()[7..];
        rs.push(Rec { ts, level, svc, method, path, req, status, dur });
    }
    rs
}

fn logs(src: &str) -> String {
    let rs = records(src);
    let (mut errors, mut slow, mut users) = (0, 0, 0);
    for r in &rs {
        errors += (r.level == "ERROR") as i64;
        if r.status >= 500 {
            slow += r.dur;
        }
        users += r.path.starts_with("/v1/users") as i64;
    }
    black_box((rs[0].ts, rs[0].svc, rs[0].method, rs[0].req));
    format!("{},{},{},{}", rs.len(), errors, slow, users)
}

// ---- out: building output ----

struct Person<'a> {
    id: i64,
    score: i64,
    name: &'a str,
    email: &'a str,
    tags: Vec<&'a str>,
}

fn people(src: &str, limit: i64) -> Vec<Person<'_>> {
    src.lines()
        .take(limit as usize)
        .map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            Person {
                id: digits(f[0]),
                name: f[1],
                email: f[2],
                score: digits(f[3]),
                tags: f[4].split(';').filter(|t| !t.is_empty()).collect(),
            }
        })
        .collect()
}

// a JSON string: the runs that need no escape go out as they are
fn json_str(o: &mut String, s: &str) {
    o.push('"');
    let mut run = 0;
    for (i, c) in s.bytes().enumerate() {
        if c == b'"' || c == b'\\' || c < 0x20 {
            o.push_str(&s[run..i]);
            o.push_str(if c == b'"' { "\\\"" } else { "\\\\" });
            run = i + 1;
        }
    }
    o.push_str(&s[run..]);
    o.push('"');
}

fn out_json(ps: &[Person]) -> String {
    let mut o = String::new();
    o.push('[');
    for (r, x) in ps.iter().enumerate() {
        if r > 0 {
            o.push(',');
        }
        o.push_str("{\"id\":");
        write!(o, "{}", x.id).unwrap();
        o.push_str(",\"name\":");
        json_str(&mut o, x.name);
        o.push_str(",\"email\":");
        json_str(&mut o, x.email);
        o.push_str(",\"score\":");
        write!(o, "{}", x.score).unwrap();
        o.push_str(",\"tags\":[");
        for (t, tag) in x.tags.iter().enumerate() {
            if t > 0 {
                o.push(',');
            }
            json_str(&mut o, tag);
        }
        o.push_str("]}");
    }
    o.push(']');
    format!("{},{}", ps.len(), black_box(o).len())
}

fn out_logs(rs: &[Rec]) -> String {
    let mut o = String::new();
    for r in rs {
        o.push_str("ts=");
        o.push_str(r.ts);
        o.push_str(" level=");
        o.push_str(r.level);
        o.push_str(" svc=");
        o.push_str(r.svc);
        o.push_str(" method=");
        o.push_str(r.method);
        o.push_str(" path=\"");
        o.push_str(r.path);
        o.push_str("\" status=");
        write!(o, "{}", r.status).unwrap();
        o.push_str(" dur_ms=");
        write!(o, "{}", r.dur).unwrap();
        o.push_str(" req_id=");
        o.push_str(r.req);
        o.push('\n');
    }
    format!("{},{}", rs.len(), black_box(o).len())
}

// gen.c's 2,000 cities at 1,000,000, and at least 4
fn cities(n: i64) -> i64 {
    if n >= 2000 { n / 500 } else { 4 }
}

fn arg(args: &[String], i: usize) -> i64 {
    args[i].parse().unwrap()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let w = args[1].as_str();
    let n = arg(&args, 2);
    if w == "dump" {
        let dir = &args[3];
        let put = |name: &str, s: &str| std::fs::write(format!("{}/{}", dir, name), s).unwrap();
        put("tok.txt", &tok_input(n));
        put("keys.txt", &keys_input(n / 5, 4 * n));
        put("sort.txt", &sort_input(n));
        put("rows.csv", &rows_input(cities(n), 5 * n));
        put("logs.txt", &logs_input(n));
        put("people.csv", &people_input(n));
        for k in ["ascii", "cjk", "mixed"] {
            std::fs::write(format!("{}/{}-{}.txt", dir, k, n), utf8_input(k, n)).unwrap();
        }
        return;
    }
    let rounds = arg(&args, 3);
    if let Some(kind) = w.strip_prefix("utf8_") {
        let b = utf8_input(kind, n);
        println!("{}", b.len());
        let (mut ok, mut total) = (0, 0);
        for _ in 0..rounds {
            if let Ok(s) = std::str::from_utf8(black_box(&b[..])) {
                ok += 1;
                total += s.len();
            }
        }
        println!("{},{}", ok, total);
        return;
    }
    let src = match w {
        "tok" => tok_input(n),
        "map" | "map_std" => keys_input(n / 5, 4 * n),
        "sort" => sort_input(n),
        "group" | "group_std" => rows_input(cities(n), 5 * n),
        "logs" | "out_logs" => logs_input(n),
        "out_json" => people_input(n),
        _ => panic!("no workload {}", w),
    };
    println!("{}", src.len());
    let ps = if w == "out_json" { people(&src, n) } else { Vec::new() };
    let rs = if w == "out_logs" { records(&src) } else { Vec::new() };
    for _ in 0..rounds {
        let check = match w {
            "tok" => tok(&src),
            "map" => map::<FxBuild>(&src),
            "map_std" => map::<std::collections::hash_map::RandomState>(&src),
            "sort" => sort(&src),
            "group" => group::<FxBuild>(&src),
            "group_std" => group::<std::collections::hash_map::RandomState>(&src),
            "logs" => logs(&src),
            "out_json" => out_json(&ps),
            _ => out_logs(&rs),
        };
        println!("{}", check);
    }
}
