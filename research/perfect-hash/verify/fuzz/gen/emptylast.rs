#[inline]
pub fn emptylast(s: &str) -> i64 {
    match s {
        "" => 0,
        "a1" => 1,
        "a2" => 2,
        "a3" => 3,
        "a4" => 4,
        "aa1" => 5,
        "aa2" => 6,
        "aa3" => 7,
        "aa4" => 8,
        "aaa1" => 9,
        "aaa2" => 10,
        "aaa3" => 11,
        "aaa4" => 12,
        "aaaa1" => 13,
        "aaaa2" => 14,
        "aaaa3" => 15,
        "aaaa4" => 16,
        _ => -1,
    }
}
