package protocol

import "core:fmt"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:testing"

EPSILON :: 1e-6

Compressed_Integer :: struct {
	value: i32,
	min:   i32,
	max:   i32,
}

Compressed_Float :: struct {
	value:      f32,
	min:        f32,
	max:        f32,
	resolution: f32,
}

Compressed_Vector2 :: struct {
	value:      Vector2,
	min:        f32,
	max:        f32,
	resolution: f32,
}

Compressed_Vector3 :: struct {
	value:      Vector3,
	min:        f32,
	max:        f32,
	resolution: f32,
}

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
	bit_writer: ^Bit_Writer,
	value, min, max: i32,
) -> bool {
	assert(
		min < max,
		fmt.tprintf("assumed min %v is smaller than max %v", min, max),
	)
	assert(value >= min, fmt.tprintf("assumed value %v >= min %v", value, min))
	assert(value <= max, fmt.tprintf("assumed value %v <= max %v", value, max))
	bits := bits_required(min, max)
	unsigned_value := u32(value - min)
	success := write_bits(bit_writer, unsigned_value, u32(bits))
	return success
}

@(require_results)
deserialize_integer :: proc(
	bit_reader: ^Bit_Reader,
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
serialize_bool :: proc(bit_writer: ^Bit_Writer, val: bool) -> bool {
	write_bits(bit_writer, u32(val), 1) or_return
	return true
}

@(require_results)
deserialize_bool :: proc(bit_reader: ^Bit_Reader) -> (bool, bool) {
	val, success := read_bits(bit_reader, 1)
	if !success {
		return false, false
	}

	return bool(val), true
}

@(require_results)
serialize_float :: proc(bit_writer: ^Bit_Writer, value: f32) -> bool {
	int_value := transmute(u32)value
	return write_bits(bit_writer, int_value, 32)
}

@(require_results)
deserialize_float :: proc(bit_reader: ^Bit_Reader) -> (f32, bool) {
	int_value, success := read_bits(bit_reader, 32)
	if !success {
		return 0, false
	}
	return transmute(f32)int_value, true
}

// Serializes a compressed float value between min and max with the resolution given.
// NOTE: Its important that the serialization and deserialization procedures uses the
// same min, max and resolution values for this work properly.
// NOTE: This will be numerically unstable at high values depending on the resolution.
//
// The idea behind how the compression works is that a floating point 
// value with a resolution of 0.01 in the range of [0, 10] can represent
// 1000 distinct values. Now we can represent the same amount of values in 
// "integer space" by scaling up by a factor of the inverse of the resolution, meaning 1/0.01 = 1000
// Then we can just serialize this as normal, meaning writing it as a u32 word and specifying the
// number of bits to the Bit_Writer. This way for a value between 0,10, we went from having to use 32 bits
// to represent it to 9 bits instead.
@(require_results)
serialize_compressed_float :: proc(
	bit_writer: ^Bit_Writer,
	value: f32,
	min: f32,
	max: f32,
	resolution: f32,
) -> bool {
	assert(
		min < max,
		fmt.tprintf("assumed min %v is smaller than max %v", min, max),
	)
	assert(
		resolution != 0.0,
		fmt.tprintf("assumed resolution is not equal to 0.0"),
	)
	// Example 
	// value = 15
	// min = 10
	// max = 20
	// resolution = 0.01
	// Then we'll get the following:
	// delta = 20 - 10 = 10 
	// values = 10 / 0.01 = 1000
	// max_integer_value = ceil(1000) = 1000
	// This means that 100 is the largest value we can
	// represent with the current, min, max and resolution values
	// required_bits = bits_required(0, 1000) = 9
	// 
	// normalized value = clamp((15 - 10 ) / 10, 0, 1)
	// normalized_value = clamp(0.5, 0, 1) = 0.5, since 0 < 0.5 < 1
	// integer_value = floor(0.5 * 1000 + 0.5) = 500
	// We don't see it in this case, but the reason we're adding 0.5 here
	// is to make sure we're in the "right" whole integer that we're then flooring down to.


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


// Deserializes a compressed float value between min and max with the resolution given.
// NOTE: Its important that the serialization and deserialization procedures uses the
// same min, max and resolution values for this work properly.
// NOTE: This will be numerically unstable at high values depending on the resolution.
// The idea behind how the compression works is that a floating point 
// value with a resolution of 0.01 in the range of [0, 10] can represent
// 1000 distinct values. Now we can represent the same amount of values in 
// "integer space" by scaling up by a factor of the inverse of the resolution, meaning 1/0.01 = 1000
// Then we can just serialize this as normal, meaning writing it as a u32 word and specifying the
// number of bits to the Bit_Writer. This way for a value between 0,10, we went from having to use 32 bits
// to represent it to 9 bits instead.
@(require_results)
deserialize_compressed_float :: proc(
	bit_reader: ^Bit_Reader,
	min: f32,
	max: f32,
	resolution: f32,
) -> (
	f32,
	bool,
) {
	assert(
		min < max,
		fmt.tprintf("assumed min %v is smaller than max %v", min, max),
	)
	assert(
		resolution != 0.0,
		fmt.tprintf("assumed resolution is not equal to 0.0"),
	)

	// Example - continuing from the serialization above
	// min = 10
	// max = 20
	// resolution = 0.01
	// delta = 20 - 10 = 10
	// values = 10 / 0.01 = 1000
	// max_integer_value = ceil(1000) = 1000
	// required_bites = bits_required(1000) = 9
	// integer_value = read_bits(bit_reader, 9) = 500 (We know that this is what the serialization function wrote)
	// normalized_value := f32(500) / f32(1000) = 0.5
	// value = 0.5 * 10 + 10 = 5 + 10 = 15

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
Quaternion :: [4]f32

@(require_results)
serialize_vector2 :: proc(bit_writer: ^Bit_Writer, value: Vector2) -> bool {
	if !serialize_float(bit_writer, value[0]) {
		return false
	}
	if !serialize_float(bit_writer, value[1]) {
		return false
	}

	return true
}

@(require_results)
deserialize_vector2 :: proc(bit_reader: ^Bit_Reader) -> (Vector2, bool) {
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
serialize_vector3 :: proc(bit_writer: ^Bit_Writer, value: Vector3) -> bool {
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
deserialize_vector3 :: proc(bit_reader: ^Bit_Reader) -> (Vector3, bool) {
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

@(require_results)
serialize_compressed_vector2 :: proc(
	bit_writer: ^Bit_Writer,
	vec2: Vector2,
	min: f32,
	max: f32,
	resolution: f32,
) -> bool {
	if !serialize_compressed_float(bit_writer, vec2[0], min, max, resolution) {
		return false
	}

	if !serialize_compressed_float(bit_writer, vec2[1], min, max, resolution) {
		return false
	}
	return true
}

@(require_results)
deserialize_compressed_vector2 :: proc(
	bit_reader: ^Bit_Reader,
	min: f32,
	max: f32,
	resolution: f32,
) -> (
	Vector2,
	bool,
) {
	x, success1 := deserialize_compressed_float(
		bit_reader,
		min,
		max,
		resolution,
	)
	if !success1 {
		return {}, false
	}

	y, success2 := deserialize_compressed_float(
		bit_reader,
		min,
		max,
		resolution,
	)
	if !success2 {
		return {}, false
	}

	return Vector2{x, y}, true
}

@(require_results)
serialize_compressed_vector3 :: proc(
	bit_writer: ^Bit_Writer,
	vec3: Vector3,
	min: f32,
	max: f32,
	resolution: f32,
) -> bool {
	if !serialize_compressed_float(bit_writer, vec3[0], min, max, resolution) {
		return false
	}

	if !serialize_compressed_float(bit_writer, vec3[1], min, max, resolution) {
		return false
	}

	if !serialize_compressed_float(bit_writer, vec3[2], min, max, resolution) {
		return false
	}

	return true
}

@(require_results)
deserialize_compressed_vector3 :: proc(
	bit_reader: ^Bit_Reader,
	min: f32,
	max: f32,
	resolution: f32,
) -> (
	Vector3,
	bool,
) {
	x, success1 := deserialize_compressed_float(
		bit_reader,
		min,
		max,
		resolution,
	)
	if !success1 {
		return Vector3{}, false
	}

	y, success2 := deserialize_compressed_float(
		bit_reader,
		min,
		max,
		resolution,
	)
	if !success2 {
		return Vector3{}, false
	}

	z, success3 := deserialize_compressed_float(
		bit_reader,
		min,
		max,
		resolution,
	)
	if !success3 {
		return Vector3{}, false
	}

	return Vector3{x, y, z}, true
}

@(require_results)
serialize_quaternion :: proc(
	bit_writer: ^Bit_Writer,
	quat: Quaternion,
) -> bool {
	if !serialize_float(bit_writer, quat[0]) {
		return false
	}

	if !serialize_float(bit_writer, quat[1]) {
		return false
	}

	if !serialize_float(bit_writer, quat[2]) {
		return false
	}

	if !serialize_float(bit_writer, quat[3]) {
		return false
	}

	return true
}

// TODO(Thomas): Add serialize and deserialize procedures for compressed_quaternion

@(require_results)
deserialize_quaternion :: proc(bit_reader: ^Bit_Reader) -> (Quaternion, bool) {
	x, success1 := deserialize_float(bit_reader)
	if !success1 {
		return Quaternion{}, false
	}

	y, success2 := deserialize_float(bit_reader)
	if !success2 {
		return Quaternion{}, false
	}

	z, success3 := deserialize_float(bit_reader)
	if !success3 {
		return Quaternion{}, false
	}

	w, success4 := deserialize_float(bit_reader)
	if !success4 {
		return Quaternion{}, false
	}

	return Quaternion{x, y, z, w}, true
}

@(require_results)
serialize_align :: proc(bit_writer: ^Bit_Writer) -> bool {
	return write_align(bit_writer)
}

@(require_results)
deserialize_align :: proc(bit_reader: ^Bit_Reader) -> bool {
	return read_align(bit_reader)
}

@(require_results)
serialize_bytes :: proc(bit_writer: ^Bit_Writer, data: []u8) -> bool {
	assert(len(data) > 0)
	if !serialize_align(bit_writer) {
		return false
	}
	return write_bytes(bit_writer, data)
}

@(require_results)
deserialize_bytes :: proc(
	bit_reader: ^Bit_Reader,
	data: []u8,
	bytes: u32,
) -> bool {
	assert(len(data) > 0)
	assert(bytes > 0)
	if !deserialize_align(bit_reader) {
		return false
	}
	return read_bytes(bit_reader, data, bytes)
}

// Serailize string, the string 'str' cannot be larger than the buffer of the 'bit_writer' 
// If serialization of the string length integer or the string bytes fails, this procedure
// will return false.
@(require_results)
serialize_string :: proc(bit_writer: ^Bit_Writer, str: string) -> bool {
	str_bytes := transmute([]u8)str
	str_length := i32(len(str_bytes))
	buffer_size := i32(len(bit_writer.buffer))
	assert(str_length < buffer_size - 1)
	success := serialize_integer(bit_writer, str_length, 0, buffer_size - 1)
	if !success {
		return false
	}
	success = serialize_bytes(bit_writer, str_bytes)
	if !success {
		return false
	}

	return true
}

// Deserializes string from the 'bit_reader' and allocates the necessary backing memory for the string.  
// This means that it's up to the user of this procedure to ensure that the backing memory of the string is managed properly.
@(require_results)
deserialize_string :: proc(
	bit_reader: ^Bit_Reader,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	str_len, success := deserialize_integer(
		bit_reader,
		0,
		i32(len(bit_reader.buffer)),
	)
	if !success {
		return "", false
	}

	// NOTE(Thomas): We're allocating the bytes necessary for the string here.
	// This makes sures the string still has valid memory to point to after the function returns.
	// It's up to the caller of this function to make sure that the string is properly freed.
	// This is why we're giving the option of passing in an allocator, so that the user calling
	// this has more easily control over that. 
	str_bytes := make_slice([]u8, str_len, allocator)


	// Integer Safety: Should be safe to cast to u32 here due to
	// the number of bytes should always be > 0. Lets assert to be sure.
	// TODO(Thomas): Remove when stabilized?
	assert(str_len > 0)
	str_success := deserialize_bytes(bit_reader, str_bytes[:], u32(str_len))
	if !str_success {
		return "", false
	}

	str := transmute(string)str_bytes

	return str, true
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
	res = flush_bits(&writer)
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
	res = flush_bits(&writer)
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
		res = flush_bits(&writer)
		testing.expect(t, res)

		// Deserialize
		deserialized_value, success := deserialize_integer(&reader, min, max)
		testing.expect(t, success)
		testing.expect_value(t, deserialized_value, value)
	}
}

@(test)
test_serialize_deserialize_bool :: proc(t: ^testing.T) {
	// True case
	{
		buffer := []u32{0}
		writer := create_writer(buffer[:])
		reader := create_reader(buffer[:])

		val := true

		res := serialize_bool(&writer, val)
		testing.expect(t, res)

		res = flush_bits(&writer)
		testing.expect(t, res)

		deserialized_val, success := deserialize_bool(&reader)
		testing.expect(t, success)
		testing.expect_value(t, deserialized_val, val)
	}

	// False case
	{
		buffer := []u32{0}
		writer := create_writer(buffer[:])
		reader := create_reader(buffer[:])

		val := false

		res := serialize_bool(&writer, val)
		testing.expect(t, res)

		res = flush_bits(&writer)
		testing.expect(t, res)

		deserialized_val, success := deserialize_bool(&reader)
		testing.expect(t, success)
		testing.expect_value(t, deserialized_val, val)
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
	res = flush_bits(&writer)
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
	res = flush_bits(&writer)
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
test_serialize_deserialize_compressed_negative_float :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_value: f32 = -3.14159
	min: f32 = -10
	max: f32 = 0
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
	res = flush_bits(&writer)
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
	res = flush_bits(&writer)
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
	res = flush_bits(&writer)
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

@(test)
test_serialize_deserialize_compressed_vector2 :: proc(t: ^testing.T) {
	buffer := []u32{0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_vec := Vector2{3.14159, 2.71828}
	min: f32 = 0
	max: f32 = 10
	resolution: f32 = 0.01

	// Serialize
	res := serialize_compressed_vector2(
		&writer,
		original_vec,
		min,
		max,
		resolution,
	)
	testing.expect(t, res)

	// Flush to memory
	res = flush_bits(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_vec, success := deserialize_compressed_vector2(
		&reader,
		min,
		max,
		resolution,
	)
	testing.expect(t, success)

	testing.expect(
		t,
		vec2_approx_equal(original_vec, deserialized_vec, resolution),
		fmt.tprintf("Expected %v, got %v", original_vec, deserialized_vec),
	)
}


@(test)
test_serialize_deserialize_compressed_vector3 :: proc(t: ^testing.T) {
	buffer := []u32{0, 0, 0}
	writer := create_writer(buffer[:])
	reader := create_reader(buffer[:])

	original_vec := Vector3{3.14159, 2.71828, 1.61803}
	min: f32 = 0
	max: f32 = 10
	resolution: f32 = 0.01

	// Serialize
	res := serialize_compressed_vector3(
		&writer,
		original_vec,
		min,
		max,
		resolution,
	)
	testing.expect(t, res)

	// Flush to memory
	res = flush_bits(&writer)
	testing.expect(t, res)

	// Deserialize
	deserialized_vec, success := deserialize_compressed_vector3(
		&reader,
		min,
		max,
		resolution,
	)
	testing.expect(t, success)

	testing.expect(
		t,
		vec3_approx_equal(original_vec, deserialized_vec, resolution),
		fmt.tprintf("Expected %v, got %v", original_vec, deserialized_vec),
	)
}

@(test)
test_serialize_deserialize_quaternion :: proc(t: ^testing.T) {
	buffer := []u32{0, 0, 0, 0}
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	original_quat := Quaternion{3.14159, 2.71828, 1.61803, 1.41421}

	res := serialize_quaternion(&writer, original_quat)
	testing.expect(t, res)

	deserialized_quat, success := deserialize_quaternion(&reader)
	testing.expect(t, success)
	testing.expect_value(t, original_quat, deserialized_quat)
}

@(test)
test_serialize_deserialize_bytes :: proc(t: ^testing.T) {
	// Test case 1: Serialize and deserialize a small array
	{
		buffer := []u32{0}
		writer := create_writer(buffer[:])
		reader := create_reader(buffer[:])

		write_data := []u8{0xCC, 0xBB, 0xDD, 0xAA}

		success := serialize_bytes(&writer, write_data)
		testing.expect(t, success)

		read_data: [4]u8

		success = deserialize_bytes(&reader, read_data[:], 4)
		testing.expect(t, success)

		testing.expect_value(t, write_data[0], read_data[0])
		testing.expect_value(t, write_data[1], read_data[1])
		testing.expect_value(t, write_data[2], read_data[2])
		testing.expect_value(t, write_data[3], read_data[3])
	}

	// Test case 2: Serialize and deserialize a larger byte array
	{
		num_words :: 4
		buffer: [num_words]u32
		writer := create_writer(buffer[:])
		reader := create_reader(buffer[:])

		byte_len :: num_words * size_of(u32)
		write_data := []u8 {
			0x00,
			0x11,
			0x22,
			0x33,
			0x44,
			0x55,
			0x66,
			0x77,
			0x88,
			0x99,
			0xAA,
			0xBB,
			0xCC,
			0xDD,
			0xEE,
			0xFF,
		}

		read_data: [byte_len]u8

		// Serialize
		success := serialize_bytes(&writer, write_data)
		testing.expect(t, success)

		// Deserialize
		success = deserialize_bytes(&reader, read_data[:], byte_len)
		testing.expect(t, success)

		for i in 0 ..< byte_len {
			testing.expect_value(t, write_data[i], read_data[i])
		}
	}
}

@(test)
test_serialize_deserialize_string :: proc(t: ^testing.T) {
	buffer := make([]u32, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)
	writer := create_writer(buffer)
	reader := create_reader(buffer)
	str := "hello"
	success := serialize_string(&writer, str)
	testing.expect(
		t,
		success,
		fmt.tprintf("Should be able to serialize the string %s", str),
	)
	flush_success := flush_bits(&writer)
	testing.expect(t, flush_success, "Flushing the bits should be successful")

	des_str, str_success := deserialize_string(&reader, context.temp_allocator)
	testing.expect(
		t,
		str_success,
		fmt.tprintf("Should be able deserialize string %s", str),
	)
	testing.expect_value(t, des_str, str)
}

@(test)
test_serialize_deserialize_string_with_newline :: proc(t: ^testing.T) {
	buffer := make([]u32, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)
	writer := create_writer(buffer)
	reader := create_reader(buffer)
	str := "hello\nworld"
	success := serialize_string(&writer, str)
	testing.expect(
		t,
		success,
		fmt.tprint("Should be able to serialize the string '%s'", str),
	)
	flush_success := flush_bits(&writer)
	testing.expect(t, flush_success, "Flushing the bits should be successful")

	des_str, str_success := deserialize_string(&reader, context.temp_allocator)
	testing.expect(
		t,
		str_success,
		fmt.tprintf("Should be able deserialize string '%s'", str),
	)
	testing.expect_value(t, des_str, str)
}
