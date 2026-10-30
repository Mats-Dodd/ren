#[inline]
pub fn methods(s: &str) -> i64 {
    match s {
        "GET" => 0,
        "HEAD" => 1,
        "POST" => 2,
        "PUT" => 3,
        "DELETE" => 4,
        "CONNECT" => 5,
        "OPTIONS" => 6,
        "TRACE" => 7,
        "PATCH" => 8,
        _ => -1,
    }
}
#[inline]
pub fn headers(s: &str) -> i64 {
    match s {
        "Accept" => 0,
        "Accept-Encoding" => 1,
        "Authorization" => 2,
        "Cache-Control" => 3,
        "Connection" => 4,
        "Content-Length" => 5,
        "Content-Type" => 6,
        "Cookie" => 7,
        "Date" => 8,
        "Host" => 9,
        "If-None-Match" => 10,
        "Location" => 11,
        "Origin" => 12,
        "Referer" => 13,
        "Server" => 14,
        "Set-Cookie" => 15,
        "User-Agent" => 16,
        "Vary" => 17,
        "Via" => 18,
        "X-Forwarded-For" => 19,
        _ => -1,
    }
}
#[inline]
pub fn jsreserved(s: &str) -> i64 {
    match s {
        "await" => 0,
        "break" => 1,
        "case" => 2,
        "catch" => 3,
        "class" => 4,
        "const" => 5,
        "continue" => 6,
        "debugger" => 7,
        "default" => 8,
        "delete" => 9,
        "do" => 10,
        "else" => 11,
        "enum" => 12,
        "export" => 13,
        "extends" => 14,
        "false" => 15,
        "finally" => 16,
        "for" => 17,
        "function" => 18,
        "if" => 19,
        "import" => 20,
        "in" => 21,
        "instanceof" => 22,
        "new" => 23,
        "null" => 24,
        "return" => 25,
        "super" => 26,
        "switch" => 27,
        "this" => 28,
        "throw" => 29,
        "true" => 30,
        "try" => 31,
        "typeof" => 32,
        "var" => 33,
        "void" => 34,
        "while" => 35,
        "with" => 36,
        "yield" => 37,
        "implements" => 38,
        "interface" => 39,
        "package" => 40,
        "private" => 41,
        "protected" => 42,
        "public" => 43,
        "static" => 44,
        _ => -1,
    }
}
#[inline]
pub fn json8(s: &str) -> i64 {
    match s {
        "id" => 0,
        "name" => 1,
        "email" => 2,
        "created_at" => 3,
        "updated_at" => 4,
        "status" => 5,
        "owner_id" => 6,
        "tags" => 7,
        _ => -1,
    }
}
#[inline]
pub fn json24(s: &str) -> i64 {
    match s {
        "id" => 0,
        "name" => 1,
        "email" => 2,
        "created_at" => 3,
        "updated_at" => 4,
        "deleted_at" => 5,
        "status" => 6,
        "owner_id" => 7,
        "org_id" => 8,
        "tags" => 9,
        "title" => 10,
        "description" => 11,
        "priority" => 12,
        "due_date" => 13,
        "assignee_id" => 14,
        "labels" => 15,
        "version" => 16,
        "etag" => 17,
        "parent_id" => 18,
        "metadata" => 19,
        "visibility" => 20,
        "archived" => 21,
        "last_modified_by" => 22,
        "notification_settings" => 23,
        _ => -1,
    }
}
#[inline]
pub fn schemes(s: &str) -> i64 {
    match s {
        "http" => 0,
        "https" => 1,
        "ftp" => 2,
        "ws" => 3,
        "wss" => 4,
        "file" => 5,
        _ => -1,
    }
}
#[inline]
pub fn renkw(s: &str) -> i64 {
    match s {
        "fn" => 0,
        "pub" => 1,
        "let" => 2,
        "var" => 3,
        "inout" => 4,
        "for" => 5,
        "while" => 6,
        "break" => 7,
        "todo" => 8,
        "in" => 9,
        "if" => 10,
        "then" => 11,
        "else" => 12,
        "true" => 13,
        "false" => 14,
        "type" => 15,
        "dep" => 16,
        "match" => 17,
        "import" => 18,
        "as" => 19,
        "uses" => 20,
        "opaque" => 21,
        "self" => 22,
        "not" => 23,
        "fail" => 24,
        "try" => 25,
        "attempt" => 26,
        "orelse" => 27,
        "with" => 28,
        "handler" => 29,
        "over" => 30,
        "finally" => 31,
        "test" => 32,
        "group" => 33,
        "assert" => 34,
        _ => -1,
    }
}
use std::time::Instant;

fn run<F: Fn(&str) -> i64>(set: &str, reps: usize, f: F) {
    let text = std::fs::read_to_string(format!("gen/{}.q", set)).unwrap();
    // the queries copied into one arena, 8-aligned after a 32-byte gap, as in bench.c
    let mut arena: Vec<u8> = Vec::with_capacity(65536 * 64);
    let mut spans = Vec::new();
    for l in text.lines() {
        arena.extend_from_slice(&[0u8; 32]);
        let at = arena.len();
        arena.extend_from_slice(l.as_bytes());
        spans.push((at, l.len()));
        while arena.len() % 8 != 0 { arena.push(0); }
    }
    let arena = String::from_utf8(arena).unwrap();
    let q: Vec<&str> = spans.iter().map(|&(a, n)| &arena[a..a + n]).collect();
    let mut best = f64::MAX;
    let mut sum: i64 = 0;
    for _ in 0..reps {
        let t0 = Instant::now();
        let mut s: i64 = 0;
        for x in std::hint::black_box(&q).iter() { s += f(x); }
        let t = t0.elapsed().as_nanos() as f64;
        if t < best { best = t; }
        sum += s;
    }
    println!("{}", sum);
    eprintln!("{} rust {:.3} ns/lookup (min of {} passes)", set, best / q.len() as f64, reps);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let reps: usize = a[2].parse().unwrap();
    let s = a[1].as_str();
    match s {
        "methods" => run(s, reps, methods), "headers" => run(s, reps, headers),
        "jsreserved" => run(s, reps, jsreserved), "json8" => run(s, reps, json8),
        "json24" => run(s, reps, json24), "schemes" => run(s, reps, schemes),
        "renkw" => run(s, reps, renkw), _ => panic!("set"),
    }
}
