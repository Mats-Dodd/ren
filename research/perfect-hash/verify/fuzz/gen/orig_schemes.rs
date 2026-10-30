#[inline]
pub fn orig_schemes(s: &str) -> i64 {
    match s {
        "http" => 0,
        "https" => 1,
        "ftp" => 2,
        "ws" => 3,
        "wss" => 4,
        "file" => 5,
        _ => -1,
    }
}
