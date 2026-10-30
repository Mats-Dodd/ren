#[inline]
pub fn emptylast2(s: &str) -> i64 {
    match s {
        "" => 0,
        "x" => 1,
        "y" => 2,
        "z" => 3,
        "wx" => 4,
        "wy" => 5,
        "wz" => 6,
        "wwx" => 7,
        "wwy" => 8,
        "wwz" => 9,
        "wwwx" => 10,
        "wwwy" => 11,
        "wwwz" => 12,
        "wwwwx" => 13,
        "wwwwy" => 14,
        "wwwwz" => 15,
        "wwwwwx" => 16,
        "wwwwwy" => 17,
        "wwwwwz" => 18,
        _ => -1,
    }
}
