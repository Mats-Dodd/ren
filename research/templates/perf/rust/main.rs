// Rust twins for the template prototype: std only, one thread.
//   main <variant> [n]
// log-write   write!(out, "...") into a reused String: fmt::Arguments, no allocation
// log-format  format!("...") then out.push_str: one String per line
// sql-static  sqlx query!-style: &'static str text, params a Vec<Param> per call
// sql-reuse   static text, params pushed into a reused Vec (the best Rust can do)
// sql-build   text built per call with write!("${}") into a reused String, params reused
// html-write  write! with an Escape(&str) Display wrapper into a reused String
// html-format format! of the same, then push_str
// Built with --cfg count, a counting allocator reports allocations on stderr.
use std::fmt::{self, Write};

#[cfg(count)]
mod counting {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
    pub static ALLOCS: AtomicU64 = AtomicU64::new(0);
    pub struct Counting;
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 { ALLOCS.fetch_add(1, Relaxed); System.alloc(l) }
        unsafe fn dealloc(&self, p: *mut u8, l: Layout) { System.dealloc(p, l) }
        unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 { ALLOCS.fetch_add(1, Relaxed); System.realloc(p, l, n) }
    }
    #[global_allocator]
    static A: Counting = Counting;
}

#[inline(never)]
fn log_write(out: &mut String, level: &str, path: &str, status: i64, ms: i64) {
    write!(out, "level={} path={} status={} ms={}\n", level, path, status, ms).unwrap();
}
#[inline(never)]
fn log_format(level: &str, path: &str, status: i64, ms: i64) -> String {
    format!("level={} path={} status={} ms={}\n", level, path, status, ms)
}

fn flush(out: &mut String, total: &mut i64) {
    if out.len() > 4096 {
        *total += out.len() as i64 + out.as_bytes()[out.len() - 2] as i64;
        out.clear();
    }
}

fn run_log(v: &str, n: i64) {
    let levels = ["info", "warn"];
    let path = "/api/jobs";
    let mut out = String::with_capacity(8192);
    let mut total = 0i64;
    for i in 0..n {
        let level = levels[(i & 1) as usize];
        let (status, ms) = (200 + i % 7, i % 1000);
        match v {
            "log-write" => log_write(&mut out, level, path, status, ms),
            "log-format" => { let s = log_format(level, path, status, ms); out.push_str(&s); }
            _ => panic!("unknown variant"),
        }
        flush(&mut out, &mut total);
    }
    println!("{}", total + out.len() as i64);
}

enum Param<'a> { Int(i64), Str(&'a str) }
const Q: &str = "select id, name, state from jobs where owner = $1 and state = $2 and created_at > $3 order by id limit $4";

fn consume(text: &str, ps: &[Param]) -> i64 {
    let mut x = text.len() as i64 + text.as_bytes()[text.len() - 1] as i64;
    for p in ps { x += match p { Param::Int(i) => *i, Param::Str(s) => s.len() as i64 }; }
    x
}
#[inline(never)]
fn sql_static(owner: i64, state: &str, since: i64, n: i64) -> i64 {
    let ps = vec![Param::Int(owner), Param::Str(state), Param::Int(since), Param::Int(n)];
    consume(Q, &ps)
}
#[inline(never)]
fn sql_reuse<'a>(ps: &mut Vec<Param<'a>>, owner: i64, state: &'a str, since: i64, n: i64) -> i64 {
    ps.clear();
    ps.push(Param::Int(owner)); ps.push(Param::Str(state)); ps.push(Param::Int(since)); ps.push(Param::Int(n));
    consume(Q, ps)
}
#[inline(never)]
fn sql_build<'a>(text: &mut String, ps: &mut Vec<Param<'a>>, owner: i64, state: &'a str, since: i64, n: i64) -> i64 {
    text.clear(); ps.clear();
    text.push_str("select id, name, state from jobs where owner = ");
    ps.push(Param::Int(owner)); write!(text, "${}", ps.len()).unwrap();
    text.push_str(" and state = ");
    ps.push(Param::Str(state)); write!(text, "${}", ps.len()).unwrap();
    text.push_str(" and created_at > ");
    ps.push(Param::Int(since)); write!(text, "${}", ps.len()).unwrap();
    text.push_str(" order by id limit ");
    ps.push(Param::Int(n)); write!(text, "${}", ps.len()).unwrap();
    consume(text, ps)
}
fn run_sql(v: &str, n: i64) {
    let states = ["queued", "running"];
    let mut text = String::with_capacity(256);
    let mut ps: Vec<Param> = Vec::with_capacity(8);
    let mut total = 0i64;
    for i in 0..n {
        let (owner, since, lim) = (i % 977, 1700000000 + i, 50 + (i & 15));
        let state = states[(i & 1) as usize];
        total += match v {
            "sql-static" => sql_static(owner, state, since, lim),
            "sql-reuse" => sql_reuse(&mut ps, owner, state, since, lim),
            "sql-build" => sql_build(&mut text, &mut ps, owner, state, since, lim),
            _ => panic!("unknown variant"),
        };
    }
    println!("{}", total);
}

struct Escape<'a>(&'a str);
impl fmt::Display for Escape<'_> {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let b = self.0.as_bytes();
        let mut from = 0;
        for (i, &c) in b.iter().enumerate() {
            let r = match c { b'&' => "&amp;", b'<' => "&lt;", b'>' => "&gt;", b'"' => "&quot;", b'\'' => "&#39;", _ => continue };
            f.write_str(&self.0[from..i])?;
            f.write_str(r)?;
            from = i + 1;
        }
        f.write_str(&self.0[from..])
    }
}
#[inline(never)]
fn html_write(out: &mut String, cls: &str, id: i64, name: &str, title: &str, bio: &str) {
    write!(out, "<li class=\"{}\"><a href=\"/u/{}\">{}</a><span title=\"{}\">{}</span></li>\n",
        Escape(cls), id, Escape(name), Escape(title), Escape(bio)).unwrap();
}
#[inline(never)]
fn html_format(cls: &str, id: i64, name: &str, title: &str, bio: &str) -> String {
    format!("<li class=\"{}\"><a href=\"/u/{}\">{}</a><span title=\"{}\">{}</span></li>\n",
        Escape(cls), id, Escape(name), Escape(title), Escape(bio))
}
fn run_html(v: &str, n: i64) {
    let clss = ["row", "row odd"];
    let names = ["Ada Lovelace", "Tom & Jerry", "<script>x</script>", "Grace Hopper"];
    let titles = ["Engineer", "\"Lead\" dev"];
    let bios = ["Writes compilers and likes plain C.", "Ships fast, tests later; 5 > 3."];
    let mut out = String::with_capacity(8192);
    let mut total = 0i64;
    for i in 0..n {
        let (cls, name, title, bio) = (clss[(i & 1) as usize], names[(i & 3) as usize], titles[((i >> 2) & 1) as usize], bios[((i >> 1) & 1) as usize]);
        let id = i % 100000;
        match v {
            "html-write" => html_write(&mut out, cls, id, name, title, bio),
            "html-format" => { let s = html_format(cls, id, name, title, bio); out.push_str(&s); }
            _ => panic!("unknown variant"),
        }
        flush(&mut out, &mut total);
    }
    println!("{}", total + out.len() as i64);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let v = a[1].as_str();
    let n: i64 = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(10_000_000);
    if v.starts_with("log") { run_log(v, n) } else if v.starts_with("sql") { run_sql(v, n) } else { run_html(v, n) }
    #[cfg(count)]
    eprintln!("allocs {}", counting::ALLOCS.load(std::sync::atomic::Ordering::Relaxed));
}
