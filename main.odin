package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"

main :: proc() {
	logger := log.create_console_logger()
	context.logger = logger
	defer log.destroy_console_logger(logger)

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
}
