package main

import "core:math"
import "core:math/bits"
import "core:testing"

serialize_integer :: proc(
	bit_writer: ^BitWriter,
	value, min, max: i32,
) -> bool {
	assert(min < max)
	assert(value >= min)
	assert(value <= max)
	bits := bits_required(min, max)
	unsigned_value := u32(value - min)
	success := write_bits(bit_writer, unsigned_value, u32(bits))
	return success
}

deserialize_integer :: proc(
	bit_reader: ^BitReader,
	min: i32,
	max: i32,
) -> (
	i32,
	bool,
) {
	assert(min < max)
	bits := bits_required(min, max)
	unsigned_value, success := read_bits(bit_reader, u32(bits))
	if !success {
		return 0, false
	}
	value := i32(unsigned_value) + min
	return value, true
}

bits_required :: proc(min, max: i32) -> int {
	assert(min < max)
	if min == max {
		return 0
	}
	return bits.len_u32(u32(max - min))
}

@(test)
test_bits_required :: proc(t: ^testing.T) {
	testing.expect_value(t, bits_required(0, 1), 1)
	testing.expect_value(t, bits_required(0, 2), 2)
	testing.expect_value(t, bits_required(0, 3), 2)
	testing.expect_value(t, bits_required(0, 4), 3)
	testing.expect_value(t, bits_required(0, 7), 3)
	testing.expect_value(t, bits_required(0, 8), 4)
	testing.expect_value(t, bits_required(0, 255), 8)
	testing.expect_value(t, bits_required(0, 256), 9)
	testing.expect_value(t, bits_required(1, 10), 4)
	testing.expect_value(t, bits_required(1000, 1100), 7)
	testing.expect_value(t, bits_required(-50, 50), 7)
	testing.expect_value(t, bits_required(-128, 127), 8)
}

@(test)
test_serialize_integer :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	value: i32 = 0x14
	min: i32 = 0x00
	max: i32 = 0x14
	res := serialize_integer(&writer, value, min, max)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0x14)
}

@(test)
test_serialize_negative_integer :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	value: i32 = -0x14
	min: i32 = -0x14
	max: i32 = 0x00
	res := serialize_integer(&writer, value, min, max)
	testing.expect(t, res)
	testing.expect_value(t, writer.scratch, 0)
}

@(test)
test_serialize_deserialize_integer :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value: i32 = 42
	min: i32 = 0
	max: i32 = 50

	// Serialize
	res := serialize_integer(&writer, original_value, min, max)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_integer(&reader, min, max)
	testing.expect(t, success)
	testing.expect_value(t, deserialized_value, original_value)
}

@(test)
test_serialize_deserialize_negative_integer :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value: i32 = -23
	min: i32 = -23
	max: i32 = 0

	// Serialize
	res := serialize_integer(&writer, original_value, min, max)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_integer(&reader, min, max)
	testing.expect(t, success)
	testing.expect_value(t, deserialized_value, original_value)
}

@(test)
test_serialize_deserialize_edge_cases :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	test_cases := [][3]i32 {
		{-128, -128, 127}, // Minimum value
		{127, -128, 127}, // Maximum value
		{0, -128, 127}, // Zero
		{-1, -1, 0}, // Negative to zero range
		{1, 1, 2}, // Positive range starting from 1
	}

	for test_case in test_cases {
		value, min, max := test_case[0], test_case[1], test_case[2]

		// Reset the writer and reader
		writer = create_writer(buffer[:])
		reader = create_reader(buffer[:])

		// Serialize
		res := serialize_integer(&writer, value, min, max)
		testing.expect(t, res)

		// Flush to memory
		res = final_flush_to_memory(&writer)
		testing.expect(t, res)

		// Deserialize
		deserialized_value, success := deserialize_integer(&reader, min, max)
		testing.expect(t, success)
		testing.expect_value(t, deserialized_value, value)
	}
}
