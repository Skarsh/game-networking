package main

import "core:fmt"
import proto "protocol"

main :: proc() {
	using proto

	fmt.println("Hellope")

	sequence_buffer := Sequence_Buffer{}
	init_sequence_buffer(sequence_buffer)
}
