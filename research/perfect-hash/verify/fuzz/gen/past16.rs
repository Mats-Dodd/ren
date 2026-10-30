#[inline]
pub fn past16(s: &str) -> i64 {
    match s {
        "xxxxxxxxxxxxxxxxxxxxaaaa" => 0,
        "xxxxxxxxxxxxxxxxxxxxaaab" => 1,
        "xxxxxxxxxxxxxxxxxxxxaaba" => 2,
        "xxxxxxxxxxxxxxxxxxxxabaa" => 3,
        "xxxxxxxxxxxxxxxxxxxxbaaa" => 4,
        "xxxxxxxxxxxxxxxxxxxxzzzz" => 5,
        "xxxxxxxxxxxxxxxxxxxxzzzy" => 6,
        "xxxxxxxxxxxxxxxxxxxx0000" => 7,
        "yyyyyyyyyyyyyyya" => 8,
        "yyyyyyyyyyyyyyyb" => 9,
        "yyyyyyyyyyyyyyyc" => 10,
        "yyyyyyyyyyyyyyyd" => 11,
        "yyyyyyyyyyyyyyye" => 12,
        "yyyyyyyyyyyyyyyf" => 13,
        "yyyyyyyyyyyyyyyg" => 14,
        "yyyyyyyyyyyyyyyh" => 15,
        "yyyyyyyyyyyyyyyya" => 16,
        "yyyyyyyyyyyyyyyyb" => 17,
        "yyyyyyyyyyyyyyyyc" => 18,
        "yyyyyyyyyyyyyyyyd" => 19,
        "qqqqqqqqqqqqqqqqq" => 20,
        "qqqqqqqqqqqqqqqqqq" => 21,
        "qqqqqqqqqqqqqqqqqqq" => 22,
        _ => -1,
    }
}
