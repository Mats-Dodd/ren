// The n-body simulation, from the Benchmarks Game, with the arithmetic
// in the same order as bench.ren, so the energies agree to the last bit.

use std::env;

#[derive(Clone, Copy)]
struct Body {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    mass: f64,
}

const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

fn planet(x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64) -> Body {
    let d = DAYS_PER_YEAR;
    Body {
        x,
        y,
        z,
        vx: vx * d,
        vy: vy * d,
        vz: vz * d,
        mass: mass * SOLAR_MASS,
    }
}

// the rows as the Benchmarks Game writes them
#[rustfmt::skip]
fn system() -> [Body; 5] {
    [
        Body { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: SOLAR_MASS },
        // Jupiter
        planet(
            4.84143144246472090, -1.16032004402742839, -0.103622044471123109,
            0.00166007664274403694, 0.00769901118419740425, -0.0000690460016972063023,
            0.000954791938424326609,
        ),
        // Saturn
        planet(
            8.34336671824457987, 4.12479856412430479, -0.403523417114321381,
            -0.00276742510726862411, 0.00499852801234917238, 0.0000230417297573763929,
            0.000285885980666130812,
        ),
        // Uranus
        planet(
            12.8943695621391310, -15.1111514016986312, -0.223307578892655734,
            0.00296460137564761618, 0.00237847173959480950, -0.0000296589568540237556,
            0.0000436624404335156298,
        ),
        // Neptune
        planet(
            15.3796971148509165, -25.9193146099879641, 0.179258772950371181,
            0.00268067772490389322, 0.00162824170038242295, -0.0000951592254519715870,
            0.0000515138902046611451,
        ),
    ]
}

fn offset_momentum(bodies: &mut [Body]) {
    let (mut px, mut py, mut pz) = (0.0, 0.0, 0.0);
    for b in bodies.iter() {
        px += b.vx * b.mass;
        py += b.vy * b.mass;
        pz += b.vz * b.mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
}

fn energy(bodies: &[Body]) -> f64 {
    let mut e = 0.0;
    for i in 0..bodies.len() {
        let b = &bodies[i];
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for c in &bodies[i + 1..] {
            let dx = b.x - c.x;
            let dy = b.y - c.y;
            let dz = b.z - c.z;
            e -= b.mass * c.mass / (dx * dx + dy * dy + dz * dz).sqrt();
        }
    }
    e
}

fn advance(bodies: &mut [Body], dt: f64) {
    for i in 0..bodies.len() {
        let (head, tail) = bodies.split_at_mut(i + 1);
        let bi = &mut head[i];
        for bj in tail.iter_mut() {
            let dx = bi.x - bj.x;
            let dy = bi.y - bj.y;
            let dz = bi.z - bj.z;
            let d2 = dx * dx + dy * dy + dz * dz;
            let mag = dt / (d2 * d2.sqrt());
            let mi = bi.mass * mag;
            let mj = bj.mass * mag;
            bi.vx -= dx * mj;
            bi.vy -= dy * mj;
            bi.vz -= dz * mj;
            bj.vx += dx * mi;
            bj.vy += dy * mi;
            bj.vz += dz * mi;
        }
    }
    for b in bodies.iter_mut() {
        b.x += dt * b.vx;
        b.y += dt * b.vy;
        b.z += dt * b.vz;
    }
}

// `x` to nine places, from the nearest whole number of billionths, as
// bench.ren shows it
fn nine_places(x: f64) -> String {
    let n = (x * 1000000000.0).round() as i64;
    let a = n.abs();
    let sign = if n < 0 { "-" } else { "" };
    format!("{}{}.{:09}", sign, a / 1000000000, a % 1000000000)
}

fn main() {
    let n: i64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(50_000_000);
    let mut bodies = system();
    offset_momentum(&mut bodies);
    println!("{}", nine_places(energy(&bodies)));
    for _ in 0..n {
        advance(&mut bodies, 0.01);
    }
    println!("{}", nine_places(energy(&bodies)));
}
