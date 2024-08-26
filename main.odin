package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"

TestData :: union {
	Vector2,
	Vector3,
	Quaternion,
}

random_test_data_type :: proc(lo: f32, hi: f32) -> TestData {
	info := type_info_of(TestData)
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
	case:
		unreachable()
	}
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

random_quaternion :: proc(lo: f32, hi: f32) -> Quaternion {
	return Quaternion {
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
		rand.float32_range(lo, hi),
	}
}

serialize_test_data :: proc(
	bit_writer: ^BitWriter,
	test_data: TestData,
) -> bool {
	switch data in test_data {
	case Vector2:
		return serialize_vector2(bit_writer, data)
	case Vector3:
		return serialize_vector3(bit_writer, data)
	case Quaternion:
		return serialize_quaternion(bit_writer, data)
	case:
		unreachable()
	}
}

deserialize_test_data :: proc(
	bit_reader: ^BitReader,
	test_data: TestData,
) -> (
	TestData,
	bool,
) {
	switch data in test_data {
	case Vector2:
		value, success := deserialize_vector2(bit_reader)
		assert(success)
		assert(value == data)
		return value, true
	case Vector3:
		value, success := deserialize_vector3(bit_reader)
		assert(success)
		assert(value == data)
		return value, true
	case Quaternion:
		value, success := deserialize_quaternion(bit_reader)
		assert(success)
		assert(value == data)
		return value, true
	case:
		unreachable()
	}
}

run_serialization_tests :: proc() {
	log.info("Serialization strategies integration tests started")
	stack: [dynamic]TestData
	num_iterations := 10_000

	buffer := make([]u32, 100_000)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	lo: f32 = -1_000_000
	hi: f32 = 1_000_000

	for i in 0 ..< num_iterations {
		// Make a random object of the different possible TestData types
		test_data := random_test_data_type(lo, hi)
		success := serialize_test_data(&writer, test_data)
		assert(success)
		append(&stack, test_data)
	}

	for i in 0 ..< num_iterations {
		test_data := stack[i]
		_, success := deserialize_test_data(&reader, test_data)
		assert(success)
	}
}

main :: proc() {
	logger := log.create_console_logger()
	context.logger = logger
	defer log.destroy_console_logger(logger)

	run_serialization_tests()

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


	packet_buffer := make([]u32, 32)
	defer delete(packet_buffer)
	packet_writer := create_writer(packet_buffer)
	packet_reader := create_reader(packet_buffer)

	fragment_packet := FragmentPacket {
		fragment_size = 72,
		crc32         = 42,
		sequence      = 16,
		packet_type   = .PacketFragment,
		fragment_id   = 14,
		num_fragments = 3,
	}

	fmt.println("len(PacketType): ", len(PacketType))

	res := serialize_fragment_packet(&packet_writer, &fragment_packet)
	assert(res)

	packet, packet_success := deserialize_fragment_packet(&packet_reader)
	assert(packet_success)


	log.info("This is a info log statement")

	protocol_id: i32 = 4
	log.info("size_of(protocol_id): ", size_of(protocol_id))
	log.info(
		"crc32: ",
		calculate_crc32(
			transmute([]byte)mem.slice_ptr(&protocol_id, size_of(protocol_id)),
		),
	)

}
