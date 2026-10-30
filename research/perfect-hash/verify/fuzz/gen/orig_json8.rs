#[inline]
pub fn orig_json8(s: &str) -> i64 {
    match s {
        "id" => 0,
        "name" => 1,
        "email" => 2,
        "created_at" => 3,
        "updated_at" => 4,
        "status" => 5,
        "owner_id" => 6,
        "tags" => 7,
        _ => -1,
    }
}
