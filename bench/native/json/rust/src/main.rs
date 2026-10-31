use serde::{Deserialize, Serialize};
#[derive(Serialize, Deserialize)]
struct Line { sku: i64, qty: i64, price: i64 }
#[derive(Serialize, Deserialize)]
struct Audit { revision: i64 }
#[derive(Serialize, Deserialize)]
enum Source { Web, Store }
#[derive(Serialize, Deserialize)]
struct Order {
    kind: String, id: i64,
    #[serde(rename = "customerId")] customer: i64,
    total: i64,
    #[serde(rename = "placedAt")] placed: i64,
    lines: Vec<Line>, note: Option<String>, source: Source, audit: Audit,
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let n: i64 = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(10000);
    let rounds: i64 = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(20);
    let inputs: Vec<String> = (0..n).map(|i| format!("{{\"kind\":\"order\",\"id\":{},\"customerId\":{},\"total\":2598,\"placedAt\":1700000000,\"lines\":[{{\"sku\":42,\"qty\":2,\"price\":1299}}],\"note\":{},\"source\":\"{}\",\"audit\":{{\"revision\":1}}}}", i+1, i%97, if i%2==0 {"null"} else {"\"deliver\""}, if i%2==0 {"Web"} else {"Store"})).collect();
    let mode = args.get(3).map(String::as_str).unwrap_or("roundtrip");
    let orders: Vec<Order> = if mode == "encode" { inputs.iter().map(|s| serde_json::from_str(s).unwrap()).collect() } else { vec![] };
    let mut sum = 0i64;
    for _ in 0..rounds {
        if mode == "encode" {
            for o in &orders {
                let text = serde_json::to_string(o).unwrap();
                sum += text.len() as i64 + text.as_bytes()[text.len()-2] as i64;
            }
            continue;
        }
        for text in &inputs {
            let o: Order = serde_json::from_str(text).unwrap();
            if mode == "decode" {
                sum += o.id + o.customer + o.total + o.placed + o.lines[0].sku + o.lines[0].qty + o.lines[0].price + o.audit.revision + o.note.as_ref().map_or(0, |s| s.len() as i64) + match o.source {Source::Web => 1, Source::Store => 2};
                continue;
            }
            let output = serde_json::to_string(&o).unwrap();
            assert_eq!(&output, text);
            sum += o.id + o.customer + o.total + o.lines[0].qty + o.audit.revision + output.len() as i64;
        }
    }
    println!("{sum}");
}
