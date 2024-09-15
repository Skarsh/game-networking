package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"

BYTE_BUFFER_SIZE :: 100

Byte_Buffer :: struct {
	data: []u8,
}

compare_byte_buffers :: proc(
	byte_buffer1: Byte_Buffer,
	byte_buffer2: Byte_Buffer,
) -> bool {
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
	Vector2,
	Vector3,
	Quaternion,
	Byte_Buffer,
	Compressed_Vector2,
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
		return random_vector2(lo, hi)
	case 1:
		return random_vector3(lo, hi)
	case 2:
		return random_quaternion(lo, hi)
	case 3:
		return random_byte_buffer(BYTE_BUFFER_SIZE)
	case 4:
		return random_compressed_vector2(lo, hi, resolution)
	case:
		unreachable()
	}
}

random_byte_buffer :: proc(size: u32) -> Byte_Buffer {
	data := make([]u8, size, context.temp_allocator)
	for i in 0 ..< len(data) {
		data[i] = u8(rand.int_max(256))
	}
	return Byte_Buffer{data}
}

random_vector2 :: proc(lo: f32, hi: f32) -> Vector2 {
	return Vector2{rand.float32_range(lo, hi), rand.float32_range(lo, hi)}
}

random_vector3 :: proc(lo: f32, hi: f32) -> Vector3 {
	return Vector3 {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

random_compressed_vector2 :: proc(
	lo: f32,
	hi: f32,
	resolution: f32,
) -> Compressed_Vector2 {
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

	return Compressed_Vector2{value, min, max, resolution}

}

random_quaternion :: proc(lo: f32, hi: f32) -> Quaternion {
	return Quaternion {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

serialize_test_data :: proc(
	bit_writer: ^Bit_Writer,
	test_data: Test_Data,
) -> bool {
	switch data in test_data {
	case Vector2:
		return serialize_vector2(bit_writer, data)
	case Vector3:
		return serialize_vector3(bit_writer, data)
	case Quaternion:
		return serialize_quaternion(bit_writer, data)
	case Byte_Buffer:
		return serialize_bytes(bit_writer, data.data)
	case Compressed_Vector2:
		return serialize_compressed_vector2(
			bit_writer,
			data.value,
			data.min,
			data.max,
			data.resolution,
		)
	case:
		unreachable()
	}
}

deserialize_test_data :: proc(
	bit_reader: ^Bit_Reader,
	test_data: Test_Data,
) -> (
	Test_Data,
	bool,
) {
	switch data in test_data {
	case Vector2:
		value, success := deserialize_vector2(bit_reader)
		assert(success, "Failed to deserialize Vector2")
		assert(
			value == data,
			fmt.tprintf(
				"Vector2's are not equal, expected %v, but got %v",
				data,
				value,
			),
		)
		return value, success
	case Vector3:
		value, success := deserialize_vector3(bit_reader)
		assert(success, "Failed to deserialize Vector3")
		assert(
			value == data,
			fmt.tprintf(
				"Vector3's are not equal, expected %v, but got %v",
				data,
				value,
			),
		)
		return value, success
	case Quaternion:
		value, success := deserialize_quaternion(bit_reader)
		assert(success, "Failed to deserialize Quaternion")
		assert(
			value == data,
			fmt.tprintf(
				"Quaternions are not equal, expected %v, but got %v",
				data,
				value,
			),
		)
		return value, success
	case Byte_Buffer:
		byte_buffer := Byte_Buffer {
			data = make([]u8, BYTE_BUFFER_SIZE, context.temp_allocator),
		}
		success := deserialize_bytes(
			bit_reader,
			byte_buffer.data,
			BYTE_BUFFER_SIZE,
		)
		assert(success, "Failed to deserialize bytes")
		assert(
			compare_byte_buffers(byte_buffer, data),
			"Byte buffers are not equal",
		)
		return byte_buffer, success
	case Compressed_Vector2:
		value, success := deserialize_compressed_vector2(
			bit_reader,
			data.min,
			data.max,
			data.resolution,
		)
		assert(success, "Failed to deserialize compressed Vector2")
		assert(
			vec2_approx_equal(value, data.value, data.resolution),
			fmt.tprintf(
				"Compressed Vector2's are not equal, expected %v but got %v, with min: %v, max: %v, resolution: %v",
				data.value,
				value,
				data.min,
				data.max,
				data.resolution,
			),
		)
		return Compressed_Vector2{value, data.min, data.max, data.resolution},
			success
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

	writer := create_writer(buffer)
	reader := create_reader(buffer)

	lo: f32 = -1_000
	hi: f32 = 1_000
	resolution: f32 = 0.01

	tests_data := make([]Test_Data, 100_000, context.temp_allocator)
	for i in 0 ..< len(tests_data) {
		log.debugf("Serializing test data for iteration: %v", i)
		tests_data[i] = random_test_data_type(lo, hi, resolution)
		log.debugf("Testdata: %v", tests_data[i])
		success := serialize_test_data(&writer, tests_data[i])
		assert(
			success,
			fmt.tprintf("Failed to serialize test_data: %v", tests_data[i]),
		)
	}

	flush_success := flush_bits(&writer)
	assert(flush_success)
	log.debugf("Flushed writer for serializing test data")

	for i in 0 ..< len(tests_data) {
		test_data := tests_data[i]
		value, success := deserialize_test_data(&reader, test_data)
		assert(
			success,
			fmt.tprintf("Failed to deserialize test_data: %v", value),
		)
	}

	assert(
		writer.bits_written == reader.bits_read,
		"Bits written is not equal to bits read",
	)

	log.debugf("writer bytes written: %v", get_writer_bytes_written(writer))
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		if len(track.allocation_map) > 0 {
			fmt.eprintf(
				"=== %v allocations not freed: ===\n",
				len(track.allocation_map),
			)
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf(
				"=== %v incorrect frees: ===\n",
				len(track.bad_free_array),
			)
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

	buffer := make([]u32, 100)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	str := "hello\nworld\nmany lines yeeees\n"
	serialize_success := serialize_string(&writer, str)
	log.infof("Serializing string: \n'%s'", str)
	assert(serialize_success)
	flush_success := flush_bits(&writer)
	assert(flush_success)

	deserialized_str, deserialize_success := deserialize_string(&reader)
	assert(deserialize_success)
	log.infof("Deserialized string: \n'%s'", deserialized_str)
}
