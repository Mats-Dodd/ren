#[inline]
pub fn quad(s: &str) -> i64 {
    match s {
        "GET" => 0,
        "HEAD" => 1,
        "POST" => 2,
        "PUT" => 3,
        _ => -1,
    }
}
