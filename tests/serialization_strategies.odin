package serialization_strategies

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

import proto "../protocol"

BYTE_BUFFER_SIZE :: 100

Byte_Buffer :: struct {
	data: []u8,
}


compare_byte_buffers :: proc(byte_buffer1: Byte_Buffer, byte_buffer2: Byte_Buffer) -> bool {
	if len(byte_buffer1.data) != len(byte_buffer2.data) {
		return false
	}

	buffer_len := len(byte_buffer1.data)
	for i in 0 ..< buffer_len {
		if byte_buffer1.data[i] != byte_buffer2.data[i] {
			return false
		}
	}

	return true
}

Test_Data :: union {
	i32,
	f32,
	proto.Vector2,
	proto.Vector3,
	proto.Quaternion,
	Byte_Buffer,
	proto.Compressed_Integer,
	proto.Compressed_Vector2,
	proto.Compressed_Vector3,
	string,
}

random_test_data_type :: proc(lo: f32, hi: f32, resolution: f32) -> Test_Data {
	info := type_info_of(Test_Data)
	variants_len := 0

	#partial switch v in info.variant {
	case runtime.Type_Info_Named:
		#partial switch vv in v.base.variant {
		case runtime.Type_Info_Union:
			variants_len = len(vv.variants)
		case:
			unreachable()
		}
	case:
		unreachable()
	}

	random := rand.int_max(variants_len)
	switch random {
	case 0:
		return random_i32()
	case 1:
		return random_f32(lo, hi)
	case 2:
		return random_vector2(lo, hi)
	case 3:
		return random_vector3(lo, hi)
	case 4:
		return random_quaternion(lo, hi)
	case 5:
		return random_byte_buffer(u32(rand.float32_range(1, BYTE_BUFFER_SIZE)))
	case 6:
		return random_compressed_integer()
	case 7:
		return random_compressed_vector2(lo, hi, resolution)
	case 8:
		return random_compressed_vector3(lo, hi, resolution)
	case 9:
		return random_string(u32(rand.float32_range(1, BYTE_BUFFER_SIZE)))
	case:
		unreachable()
	}
}

random_i32 :: proc() -> i32 {
	return rand.int31_max(math.max(i32))
}

random_f32 :: proc(lo: f32, hi: f32) -> f32 {
	return rand.float32_range(lo, hi)
}

random_byte_buffer :: proc(size: u32) -> Byte_Buffer {
	data := make([]u8, size, context.temp_allocator)
	for i in 0 ..< len(data) {
		data[i] = u8(rand.int_max(256))
	}
	return Byte_Buffer{data}
}

random_string :: proc(size: u32) -> string {
	str_bytes := random_byte_buffer(size)
	str := transmute(string)str_bytes
	return str
}

random_vector2 :: proc(lo: f32, hi: f32) -> proto.Vector2 {
	return proto.Vector2{rand.float32_range(lo, hi), rand.float32_range(lo, hi)}
}

random_vector3 :: proc(lo: f32, hi: f32) -> proto.Vector3 {
	return proto.Vector3 {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

random_compressed_integer :: proc() -> proto.Compressed_Integer {
	val1 := rand.int31()
	val2 := rand.int31()
	val3 := rand.int31()

	vals: [3]i32
	for i in 0 ..< len(vals) {
		vals[i] = rand.int31()
	}

	slice.sort(vals[:])

	min := vals[0]
	value := vals[1]
	max := vals[2]

	return proto.Compressed_Integer{value, min, max}
}

random_compressed_vector2 :: proc(lo: f32, hi: f32, resolution: f32) -> proto.Compressed_Vector2 {
	val1 := rand.float32_range(lo, hi)
	val2 := rand.float32_range(lo, hi)

	min: f32
	max: f32

	// NOTE(Thomas): Subtracting 0.1 here to make sure
	// that the case where val1 and val2 "equal", then the
	// one that is deemed smaller is enforced to be smaller.
	if val1 > val2 {
		min = val2 - 0.1
		max = val1
	} else {
		min = val1 - 0.1
		max = val2
	}

	value := random_vector2(min, max)

	return proto.Compressed_Vector2{value, min, max, resolution}

}

random_compressed_vector3 :: proc(lo: f32, hi: f32, resolution: f32) -> proto.Compressed_Vector3 {
	val1 := rand.float32_range(lo, hi)
	val2 := rand.float32_range(lo, hi)

	min: f32
	max: f32

	// NOTE(Thomas): Subtracting 0.1 here to make sure
	// that the case where val1 and val2 "equal", then the
	// one that is deemed smaller is enforced to be smaller.
	if val1 > val2 {
		min = val2 - 0.1
		max = val1
	} else {
		min = val1 - 0.1
		max = val2
	}

	value := random_vector3(min, max)

	return proto.Compressed_Vector3{value, min, max, resolution}

}

random_quaternion :: proc(lo: f32, hi: f32) -> proto.Quaternion {
	return proto.Quaternion {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

serialize_test_data :: proc(bit_writer: ^proto.Bit_Writer, test_data: Test_Data) -> bool {
	switch data in test_data {
	case i32:
		return proto.serialize_integer(bit_writer, data, 0, math.max(i32))
	case f32:
		return proto.serialize_float(bit_writer, data)
	case proto.Vector2:
		return proto.serialize_vector2(bit_writer, data)
	case proto.Vector3:
		return proto.serialize_vector3(bit_writer, data)
	case proto.Quaternion:
		return proto.serialize_quaternion(bit_writer, data)
	case Byte_Buffer:
		return proto.serialize_bytes(bit_writer, data.data)
	case proto.Compressed_Integer:
		return proto.serialize_integer(bit_writer, data.value, data.min, data.max)
	case proto.Compressed_Vector2:
		return proto.serialize_compressed_vector2(
			bit_writer,
			data.value,
			data.min,
			data.max,
			data.resolution,
		)
	case proto.Compressed_Vector3:
		return proto.serialize_compressed_vector3(
			bit_writer,
			data.value,
			data.min,
			data.max,
			data.resolution,
		)
	case string:
		return proto.serialize_string(bit_writer, data)
	case:
		unreachable()
	}
}

deserialize_test_data :: proc(
	bit_reader: ^proto.Bit_Reader,
	test_data: Test_Data,
) -> (
	Test_Data,
	bool,
) {
	switch data in test_data {
	case i32:
		value, success := proto.deserialize_integer(bit_reader, 0, math.max(i32))
		assert(success, "Failed to deserialize integer")
		assert(
			value == data,
			fmt.tprintf("i32's are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case f32:
		value, success := proto.deserialize_float(bit_reader)
		assert(success, "Failed to deserialize integer")
		assert(
			value == data,
			fmt.tprintf("f32's are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case proto.Vector2:
		value, success := proto.deserialize_vector2(bit_reader)
		assert(success, "Failed to deserialize Vector2")
		assert(
			value == data,
			fmt.tprintf("Vector2's are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case proto.Vector3:
		value, success := proto.deserialize_vector3(bit_reader)
		assert(success, "Failed to deserialize Vector3")
		assert(
			value == data,
			fmt.tprintf("Vector3's are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case proto.Quaternion:
		value, success := proto.deserialize_quaternion(bit_reader)
		assert(success, "Failed to deserialize Quaternion")
		assert(
			value == data,
			fmt.tprintf("Quaternions are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case Byte_Buffer:
		byte_buffer := Byte_Buffer {
			data = make([]u8, len(data.data), context.temp_allocator),
		}
		success := proto.deserialize_bytes(bit_reader, byte_buffer.data, u32(len(data.data)))
		assert(success, "Failed to deserialize bytes")
		assert(compare_byte_buffers(byte_buffer, data), "Byte buffers are not equal")
		return byte_buffer, success
	case proto.Compressed_Integer:
		value, success := proto.deserialize_integer(bit_reader, data.min, data.max)
		compressed_integer := proto.Compressed_Integer{value, data.min, data.max}
		assert(success, "Failed to deserialize integer")
		assert(
			compressed_integer == data,
			fmt.tprintf(
				"Compressed_Integer's are not equal, expected %v, but got %v",
				data,
				compressed_integer,
			),
		)
		return value, success
	case proto.Compressed_Vector2:
		value, success := proto.deserialize_compressed_vector2(
			bit_reader,
			data.min,
			data.max,
			data.resolution,
		)
		assert(success, "Failed to deserialize compressed Vector2")
		assert(
			proto.vec2_approx_equal(value, data.value, data.resolution),
			fmt.tprintf(
				"Compressed Vector2's are not equal, expected %v but got %v, with min: %v, max: %v, resolution: %v",
				data.value,
				value,
				data.min,
				data.max,
				data.resolution,
			),
		)
		return proto.Compressed_Vector2{value, data.min, data.max, data.resolution}, success
	case proto.Compressed_Vector3:
		value, success := proto.deserialize_compressed_vector3(
			bit_reader,
			data.min,
			data.max,
			data.resolution,
		)
		assert(success, "Failed to deserialize compressed Vector3")
		assert(
			proto.vec3_approx_equal(value, data.value, data.resolution),
			fmt.tprintf(
				"Compressed Vector3's are not equal, expected %v but got %v, with min: %v, max: %v, resolution: %v",
				data.value,
				value,
				data.min,
				data.max,
				data.resolution,
			),
		)
		return proto.Compressed_Vector3{value, data.min, data.max, data.resolution}, success
	case string:
		value, success := proto.deserialize_string(bit_reader, context.temp_allocator)
		log.debug("value: ", value)
		assert(success, "Failed to serialize string")
		assert(
			value == data,
			fmt.tprintf("Strings are not equal, expected %v, but got %v", data, value),
		)
		return value, success
	case:
		unreachable()
	}
}

// Runs many serializaiton tests with random data, to try to trigger asserts.
// Using temp_allocator here and freeing all to prevent running out of memory
// when doing long continous tests.
run_serialization_tests :: proc(allocator := context.temp_allocator) {
	log.info("Serialization strategies integration tests started")

	buffer := make([]u32, 1_000_000, context.temp_allocator)
	defer free_all(allocator)

	writer := proto.create_writer(buffer)
	reader := proto.create_reader(buffer)

	lo: f32 = -1_000
	hi: f32 = 1_000
	resolution: f32 = 0.01

	tests_data := make([]Test_Data, 100_000, context.temp_allocator)
	for i in 0 ..< len(tests_data) {
		log.debugf("Serializing test data for iteration: %v", i)
		tests_data[i] = random_test_data_type(lo, hi, resolution)
		log.debugf("Testdata: %v", tests_data[i])
		success := serialize_test_data(&writer, tests_data[i])
		assert(success, fmt.tprintf("Failed to serialize test_data: %v", tests_data[i]))
	}

	flush_success := proto.flush_bits(&writer)
	assert(flush_success)
	log.debugf("Flushed writer for serializing test data")

	for i in 0 ..< len(tests_data) {
		test_data := tests_data[i]
		value, success := deserialize_test_data(&reader, test_data)
		assert(success, fmt.tprintf("Failed to deserialize test_data: %v", value))
	}

	assert(writer.bits_written == reader.bits_read, "Bits written is not equal to bits read")

	log.debugf("writer bytes written: %v", proto.get_writer_bytes_written(writer))
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		if len(track.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
			for entry in track.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	logger := log.create_console_logger(log.Level.Info)
	context.logger = logger
	defer log.destroy_console_logger(logger)

	for {
		run_serialization_tests()
	}
}
