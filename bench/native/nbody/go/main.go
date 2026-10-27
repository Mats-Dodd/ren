// The n-body simulation, from the Benchmarks Game, with the arithmetic
// in the same order as bench.ren. Go may fuse a multiply and an add into
// one instruction, which rounds once instead of twice; float64(...)
// around a product stops it, so the energies agree to the last bit.
package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

type body struct {
	x, y, z, vx, vy, vz, mass float64
}

const (
	pi          = 3.141592653589793
	solarMass   = 4.0 * pi * pi
	daysPerYear = 365.24
)

func planet(x, y, z, vx, vy, vz, mass float64) body {
	d := float64(daysPerYear)
	return body{x, y, z, vx * d, vy * d, vz * d, mass * solarMass}
}

func system() []body {
	return []body{
		{0, 0, 0, 0, 0, 0, solarMass},
		// Jupiter
		planet(
			4.84143144246472090, -1.16032004402742839, -0.103622044471123109,
			0.00166007664274403694, 0.00769901118419740425, -0.0000690460016972063023,
			0.000954791938424326609),
		// Saturn
		planet(
			8.34336671824457987, 4.12479856412430479, -0.403523417114321381,
			-0.00276742510726862411, 0.00499852801234917238, 0.0000230417297573763929,
			0.000285885980666130812),
		// Uranus
		planet(
			12.8943695621391310, -15.1111514016986312, -0.223307578892655734,
			0.00296460137564761618, 0.00237847173959480950, -0.0000296589568540237556,
			0.0000436624404335156298),
		// Neptune
		planet(
			15.3796971148509165, -25.9193146099879641, 0.179258772950371181,
			0.00268067772490389322, 0.00162824170038242295, -0.0000951592254519715870,
			0.0000515138902046611451),
	}
}

func offsetMomentum(bodies []body) {
	var px, py, pz float64
	for _, b := range bodies {
		px += float64(b.vx * b.mass)
		py += float64(b.vy * b.mass)
		pz += float64(b.vz * b.mass)
	}
	bodies[0].vx = -px / solarMass
	bodies[0].vy = -py / solarMass
	bodies[0].vz = -pz / solarMass
}

func energy(bodies []body) float64 {
	e := 0.0
	for i := range bodies {
		b := &bodies[i]
		e += 0.5 * b.mass * (float64(float64(b.vx*b.vx)+float64(b.vy*b.vy)) + float64(b.vz*b.vz))
		for j := i + 1; j < len(bodies); j++ {
			c := &bodies[j]
			dx := b.x - c.x
			dy := b.y - c.y
			dz := b.z - c.z
			e -= float64(b.mass*c.mass) / math.Sqrt(float64(float64(dx*dx)+float64(dy*dy))+float64(dz*dz))
		}
	}
	return e
}

func advance(bodies []body, dt float64) {
	for i := range bodies {
		bi := &bodies[i]
		for j := i + 1; j < len(bodies); j++ {
			bj := &bodies[j]
			dx := bi.x - bj.x
			dy := bi.y - bj.y
			dz := bi.z - bj.z
			d2 := float64(float64(dx*dx)+float64(dy*dy)) + float64(dz*dz)
			mag := dt / float64(d2*math.Sqrt(d2))
			mi := bi.mass * mag
			mj := bj.mass * mag
			bi.vx -= float64(dx * mj)
			bi.vy -= float64(dy * mj)
			bi.vz -= float64(dz * mj)
			bj.vx += float64(dx * mi)
			bj.vy += float64(dy * mi)
			bj.vz += float64(dz * mi)
		}
	}
	for i := range bodies {
		b := &bodies[i]
		b.x += float64(dt * b.vx)
		b.y += float64(dt * b.vy)
		b.z += float64(dt * b.vz)
	}
}

// x to nine places, from the nearest whole number of billionths, as
// bench.ren shows it
func ninePlaces(x float64) string {
	n := int64(math.Round(x * 1000000000.0))
	a, sign := n, ""
	if n < 0 {
		a, sign = -n, "-"
	}
	return fmt.Sprintf("%s%d.%09d", sign, a/1000000000, a%1000000000)
}

func main() {
	n := 50000000
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	bodies := system()
	offsetMomentum(bodies)
	fmt.Println(ninePlaces(energy(bodies)))
	for i := 0; i < n; i++ {
		advance(bodies, 0.01)
	}
	fmt.Println(ninePlaces(energy(bodies)))
}
