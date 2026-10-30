#[inline]
pub fn empty(s: &str) -> i64 {
    match s {
        "" => 0,
        "a" => 1,
        "b" => 2,
        "ab" => 3,
        "ba" => 4,
        "GET" => 5,
        "PUT" => 6,
        "xxxxxxxxxxxxxxxx" => 7,
        "xxxxxxxxxxxxxxxxx" => 8,
        _ => -1,
    }
}
