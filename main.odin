package main

import "core:fmt"
import "core:math"

main :: proc() {
	min := math.min(int)
	max := math.max(int)
	diff := max - min
	fmt.println("min: ", min)
	fmt.println("max: ", max)
	fmt.println("max - min: ", diff)


	assert(min < max)
}
