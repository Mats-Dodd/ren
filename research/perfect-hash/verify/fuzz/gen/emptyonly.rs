#[inline]
pub fn emptyonly(s: &str) -> i64 {
    match s {
        "" => 0,
        _ => -1,
    }
}
