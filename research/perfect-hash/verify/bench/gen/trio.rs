#[inline]
pub fn trio(s: &str) -> i64 {
    match s {
        "GET" => 0,
        "PUT" => 1,
        "DELETE" => 2,
        _ => -1,
    }
}
