#[inline]
pub fn headers(s: &str) -> i64 {
    match s {
        "Accept" => 0,
        "Accept-Encoding" => 1,
        "Authorization" => 2,
        "Cache-Control" => 3,
        "Connection" => 4,
        "Content-Length" => 5,
        "Content-Type" => 6,
        "Cookie" => 7,
        "Date" => 8,
        "Host" => 9,
        "If-None-Match" => 10,
        "Location" => 11,
        "Origin" => 12,
        "Referer" => 13,
        "Server" => 14,
        "Set-Cookie" => 15,
        "User-Agent" => 16,
        "Vary" => 17,
        "Via" => 18,
        "X-Forwarded-For" => 19,
        _ => -1,
    }
}
