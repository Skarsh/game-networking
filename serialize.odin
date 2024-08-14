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
	value := i32(unsigned_value) + min

	return value, success
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
	testing.expect_value(t, i32(writer.scratch), value)
}
