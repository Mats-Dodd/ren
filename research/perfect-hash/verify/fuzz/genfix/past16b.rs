#[inline]
pub fn past16b(s: &str) -> i64 {
    match s {
        "kkkkkkkkkkkkkkkk" => 0,
        "kkkkkkkkkkkkkkkka" => 1,
        "kkkkkkkkkkkkkkkkb" => 2,
        "kkkkkkkkkkkkkkkkaa" => 3,
        "kkkkkkkkkkkkkkkkab" => 4,
        "kkkkkkkkkkkkkkkkba" => 5,
        "kkkkkkkkkkkkkkkkbb" => 6,
        "kkkkkkkkkkkkkkkkaaa" => 7,
        "kkkkkkkkkkkkkkkkzzz" => 8,
        "kkkkkkkkkkkkkkkkaaaaaaaaaa" => 9,
        "kkkkkkkkkkkkkkkkbbbbbbbbbb" => 10,
        _ => -1,
    }
}
