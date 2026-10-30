#[inline]
pub fn orig_methods(s: &str) -> i64 {
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
