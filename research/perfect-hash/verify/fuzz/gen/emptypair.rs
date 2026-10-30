#[inline]
pub fn emptypair(s: &str) -> i64 {
    match s {
        "" => 0,
        "z" => 1,
        _ => -1,
    }
}
