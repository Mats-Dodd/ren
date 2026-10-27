// Fannkuch-redux, from the Benchmarks Game, on one thread, in the order
// the sequential versions go through the permutations.
package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	n := 11
	if len(os.Args) > 1 {
		n, _ = strconv.Atoi(os.Args[1])
	}
	perm1 := make([]int, n)
	for i := range perm1 {
		perm1[i] = i
	}
	perm := make([]int, n)
	count := make([]int, n)
	maxFlips, checksum, permCount := 0, 0, 0
	r := n
outer:
	for {
		for ; r != 1; r-- {
			count[r-1] = r
		}
		copy(perm, perm1)
		flips := 0
		for k := perm[0]; k != 0; k = perm[0] {
			for i, j := 0, k; i < j; i, j = i+1, j-1 {
				perm[i], perm[j] = perm[j], perm[i]
			}
			flips++
		}
		maxFlips = max(maxFlips, flips)
		if permCount%2 == 0 {
			checksum += flips
		} else {
			checksum -= flips
		}
		// the next permutation: rotate the first r + 1 elements, until a
		// count is left
		for {
			if r == n {
				break outer
			}
			first := perm1[0]
			copy(perm1[:r], perm1[1:r+1])
			perm1[r] = first
			count[r]--
			if count[r] > 0 {
				break
			}
			r++
		}
		permCount++
	}
	fmt.Println(checksum)
	fmt.Printf("Pfannkuchen(%d) = %d\n", n, maxFlips)
}
