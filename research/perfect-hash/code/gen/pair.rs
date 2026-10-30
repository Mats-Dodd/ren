#[inline]
pub fn pair(s: &str) -> i64 {
    match s {
        "keys" => 0,
        "health" => 1,
        _ => -1,
    }
}
