package main

import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:testing"

EPSILON :: 1e-6

approx_equal :: proc "contextless" (a, b: f32, epsilon: f32) -> bool {
	return math.abs(a - b) < epsilon
}

vec2_approx_equal :: proc "contextless" (a, b: [2]f32, epsilon: f32) -> bool {
	return approx_equal(a.x, b.x, epsilon) && approx_equal(a.y, b.y, epsilon)
}

vec3_approx_equal :: proc "contextless" (a, b: [3]f32, epsilon: f32) -> bool {
	return(
		approx_equal(a.x, b.x, epsilon) &&
		approx_equal(a.y, b.y, epsilon) &&
		approx_equal(a.z, b.z, epsilon) \
	)
}

bits_required :: proc(min, max: i32) -> int {
	assert(min < max)
	if min == max {
		return 0
	}
	return bits.len_u32(u32(max - min))
}

@(require_results)
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

@(require_results)
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

@(require_results)
serialize_float :: proc(bit_writer: ^BitWriter, value: f32) -> bool {
	int_value := transmute(u32)value
	return write_bits(bit_writer, int_value, 32)
}

@(require_results)
deserialize_float :: proc(bit_reader: ^BitReader) -> (f32, bool) {
	int_value, success := read_bits(bit_reader, 32)
	if !success {
		return 0, false
	}
	return transmute(f32)int_value, true
}

@(require_results)
serialize_compressed_float :: proc(
	bit_writer: ^BitWriter,
	value: f32,
	min: f32,
	max: f32,
	resolution: f32,
) -> bool {
	assert(min < max)
	assert(resolution != 0.0)

	delta := max - min
	values := delta / resolution
	max_integer_value := u32(math.ceil(f32(values)))
	required_bits := bits_required(0, i32(max_integer_value))

	normalized_value := math.clamp((value - min) / delta, 0, 1)
	integer_value := u32(
		math.floor(normalized_value * f32(max_integer_value) + 0.5),
	)

	return write_bits(bit_writer, integer_value, u32(required_bits))
}

@(require_results)
deserialize_compressed_float :: proc(
	bit_reader: ^BitReader,
	min: f32,
	max: f32,
	resolution: f32,
) -> (
	f32,
	bool,
) {
	assert(min < max)
	assert(resolution != 0.0)

	delta := max - min
	values := delta / resolution
	max_integer_value := u32(math.ceil(f32(values)))
	required_bits := bits_required(0, i32(max_integer_value))

	integer_value, success := read_bits(bit_reader, u32(required_bits))
	if !success {
		return 0, false
	}

	normalized_value := f32(integer_value) / f32(max_integer_value)
	value := normalized_value * delta + min
	return value, true
}

Vector2 :: [2]f32
Vector3 :: [3]f32

@(require_results)
serialize_vector2 :: proc(bit_writer: ^BitWriter, value: Vector2) -> bool {
	if !serialize_float(bit_writer, value[0]) {
		return false
	}
	if !serialize_float(bit_writer, value[1]) {
		return false
	}

	return true
}

@(require_results)
deserialize_vector2 :: proc(bit_reader: ^BitReader) -> (Vector2, bool) {
	x, success1 := deserialize_float(bit_reader)
	if !success1 {
		return {}, false
	}

	y, success2 := deserialize_float(bit_reader)
	if !success2 {
		return {}, false
	}

	return Vector2{x, y}, true
}


@(require_results)
serialize_vector3 :: proc(bit_writer: ^BitWriter, value: Vector3) -> bool {
	if !serialize_float(bit_writer, value[0]) {
		return false
	}
	if !serialize_float(bit_writer, value[1]) {
		return false
	}
	if !serialize_float(bit_writer, value[2]) {
		return false
	}

	return true
}

@(require_results)
deserialize_vector3 :: proc(bit_reader: ^BitReader) -> (Vector3, bool) {
	x, success1 := deserialize_float(bit_reader)
	if !success1 {
		return {}, false
	}

	y, success2 := deserialize_float(bit_reader)
	if !success2 {
		return {}, false
	}

	z, success3 := deserialize_float(bit_reader)
	if !success3 {
		return {}, false
	}

	return Vector3{x, y, z}, true
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
	testing.expect_value(t, bits_required(math.min(i32), math.max(i32)), 32)
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

@(test)
test_serialize_deserialize_float :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value: f32 = 3.14159

	// Serialize
	res := serialize_float(&writer, original_value)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_float(&reader)
	testing.expect(t, success)
	testing.expect(
		t,
		math.abs(deserialized_value - original_value) < 0.000001,
		fmt.tprintf("Expected %f, got %f", original_value, deserialized_value),
	)
}

@(test)
test_serialize_deserialize_compressed_float :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value: f32 = 3.14159
	min: f32 = 0
	max: f32 = 10
	resolution: f32 = 0.01

	// Serialize
	res := serialize_compressed_float(
		&writer,
		original_value,
		min,
		max,
		resolution,
	)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_compressed_float(
		&reader,
		min,
		max,
		resolution,
	)
	testing.expect(t, success)
	testing.expect(
		t,
		math.abs(deserialized_value - original_value) < resolution,
		fmt.tprintf("Expected %f, got %f", original_value, deserialized_value),
	)
}

@(test)
test_serialize_deserialize_vector2 :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value := Vector2{3.14159, 2.71828}

	// Serialize
	res := serialize_vector2(&writer, original_value)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_vector2(&reader)
	testing.expect(t, success)

	testing.expect(
		t,
		vec2_approx_equal(original_value, deserialized_value, EPSILON),
		fmt.tprintf("Expected %v, got %v", original_value, deserialized_value),
	)
}

@(test)
test_serialize_deserialize_vector3 :: proc(t: ^testing.T) {
	buffer := []u32{0, 0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value := Vector3{3.14159, 2.71828, 1.61803}

	// Serialize
	res := serialize_vector3(&writer, original_value)
	testing.expect(t, res)

	// Flush to memory
	res = final_flush_to_memory(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_value, success := deserialize_vector3(&reader)
	testing.expect(t, success)

	testing.expect(
		t,
		vec3_approx_equal(original_value, deserialized_value, EPSILON),
		fmt.tprintf("Expected %v, got %v", original_value, deserialized_value),
	)
}
