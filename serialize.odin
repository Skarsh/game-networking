package main

import "core:testing"

serialize_integer :: proc(
	bit_writer: ^BitWriter,
	value, min, max: int,
) -> bool {
	assert(min < max)
	assert(value >= min)
	assert(value <= max)

	bits := bits_required(min, max)
	unsigned_value := u32(value - min)

	write_bits(bit_writer, u32(value), u32(bits))
	return true
}

bits_required :: proc(min, max: int) -> int {
	assert(min < max)

	if min == max {
		return 0
	}

	return u64_bits_required(u64(max - min))
}

u64_bits_required :: proc(value: u64) -> int {
	result := 0
	v := value

	for v > 0 {
		v >>= 1
		result += 1
	}

	return result
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
test_u64_bits_required :: proc(t: ^testing.T) {
	testing.expect_value(t, u64_bits_required(0), 0)
	testing.expect_value(t, u64_bits_required(1), 1)
	testing.expect_value(t, u64_bits_required(2), 2)
	testing.expect_value(t, u64_bits_required(3), 2)
	testing.expect_value(t, u64_bits_required(4), 3)
	testing.expect_value(t, u64_bits_required(7), 3)
	testing.expect_value(t, u64_bits_required(8), 4)
	testing.expect_value(t, u64_bits_required(255), 8)
	testing.expect_value(t, u64_bits_required(256), 9)
	testing.expect_value(t, u64_bits_required(u64(1) << 63), 64)
}
