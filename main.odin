package main

import "core:fmt"

main :: proc() {
	writer := BitWriter{}

	val: u32 = 1

	write_bits(&writer, val, 1)

}


