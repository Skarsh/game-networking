package main

import "core:fmt"
import "core:math"
import "core:mem"

main :: proc() {
	min := math.min(int)
	max := math.max(int)
	diff := max - min
	fmt.println("min: ", min)
	fmt.println("max: ", max)
	fmt.println("max - min: ", diff)


	assert(min < max)

	u32_slice := []u32{0xFFFF_FFFF, 0xEEEE_EEEE, 0xDDDD_DDDD, 0xCCCC_CCCC}

	byte_size := len(u32_slice) * size_of(u32)

	byte_slice := transmute([]byte)mem.slice_ptr(&u32_slice[0], byte_size)

	fmt.printf("Original u32 slice %v\n", u32_slice)
	fmt.printf("Transmuted byte slice %v\n", byte_slice)


	buffer := []u32{0xDDCCBBAA}
	fmt.println("buffer: ", buffer)
	reader := create_reader(buffer)
	data := []u8{0, 0, 0}
	success := read_bytes(&reader, data, 3)

	if success {
		fmt.println("")
	}

}
