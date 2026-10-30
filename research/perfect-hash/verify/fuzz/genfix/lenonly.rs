#[inline]
pub fn lenonly(s: &str) -> i64 {
    match s {
        "a" => 0,
        "bb" => 1,
        "ccc" => 2,
        "dddd" => 3,
        "eeeee" => 4,
        "ffffffffffffffff" => 5,
        "ggggggggggggggggg" => 6,
        "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh" => 7,
        _ => -1,
    }
}
