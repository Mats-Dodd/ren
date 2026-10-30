// The keyword kernel's Rust twin (bench/native/keywords, gen.py): each
// set a plain `match`, rmatch.rs's shape. `main <set> <n> <rounds>`.
use std::env;

#[inline]
fn renkw(s: &str) -> i64 {
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

#[inline]
fn jsreserved(s: &str) -> i64 {
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
fn methods(s: &str) -> i64 {
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
fn headers(s: &str) -> i64 {
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
fn json24(s: &str) -> i64 {
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

fn keys(set: &str) -> Vec<&'static str> {
    match set {
        "renkw" => vec!["fn", "pub", "let", "var", "inout", "for", "while", "break", "todo", "in", "if", "then", "else", "true", "false", "type", "dep", "match", "import", "as", "uses", "opaque", "self", "not", "fail", "try", "attempt", "orelse", "with", "handler", "over", "finally", "test", "group", "assert"],
        "jsreserved" => vec!["await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield", "implements", "interface", "package", "private", "protected", "public", "static"],
        "methods" => vec!["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"],
        "headers" => vec!["Accept", "Accept-Encoding", "Authorization", "Cache-Control", "Connection", "Content-Length", "Content-Type", "Cookie", "Date", "Host", "If-None-Match", "Location", "Origin", "Referer", "Server", "Set-Cookie", "User-Agent", "Vary", "Via", "X-Forwarded-For"],
        "json24" => vec!["id", "name", "email", "created_at", "updated_at", "deleted_at", "status", "owner_id", "org_id", "tags", "title", "description", "priority", "due_date", "assignee_id", "labels", "version", "etag", "parent_id", "metadata", "visibility", "archived", "last_modified_by", "notification_settings"],
        _ => vec![],
    }
}

fn next(x: i64) -> i64 {
    (x * 1103515245 + 12345) % 2147483648
}

fn queries(keys: &[&str], n: usize) -> Vec<String> {
    let mut qs = Vec::with_capacity(n);
    let mut x: i64 = 42;
    for _ in 0..n {
        x = next(x);
        let k = keys[(x % keys.len() as i64) as usize];
        x = next(x);
        if x % 10 != 0 {
            qs.push(k.to_string());
        } else if x / 10 % 2 == 0 {
            qs.push(format!("{}_", k));
        } else {
            qs.push(format!("{}#", &k[..k.len() - 1]));
        }
    }
    qs
}

fn rounds(f: fn(&str) -> i64, qs: &[String], r: usize) -> i64 {
    let mut t = 0;
    for _ in 0..r {
        for q in qs {
            t += f(q) + 1;
        }
    }
    t
}

fn main() {
    let a: Vec<String> = env::args().collect();
    let set = a[1].as_str();
    let n: usize = a[2].parse().unwrap();
    let r: usize = a[3].parse().unwrap();
    let qs = queries(&keys(set), n);
    let t = match set {
        "renkw" => rounds(renkw, &qs, r),
        "jsreserved" => rounds(jsreserved, &qs, r),
        "methods" => rounds(methods, &qs, r),
        "headers" => rounds(headers, &qs, r),
        "json24" => rounds(json24, &qs, r),
        _ => 0,
    };
    println!("{}", t);
}
