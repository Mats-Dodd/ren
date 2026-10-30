#[inline]
pub fn orig_one(s: &str) -> i64 {
    match s {
        "v1" => 0,
        _ => -1,
    }
}
