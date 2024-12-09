
package fragmentation_reassembly

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import proto "../protocol"

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

	recv_arena := virtual.Arena{}
	recv_arena_buffer := make([]u8, 100 * 1024)
	recv_arena_alloc_err := virtual.arena_init_buffer(&recv_arena, recv_arena_buffer)
	assert(recv_arena_alloc_err == .None)
	recv_arena_allocator := virtual.arena_allocator(&recv_arena)
	defer delete(recv_arena_buffer)

	// TODO(Thomas): Pass in the Arena instead
	recv_stream := proto.create_recv_stream(
		context.allocator,
		recv_arena_allocator,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_recv_stream(&recv_stream)

	send_arena := virtual.Arena{}
	send_arena_buffer := make([]u8, 100 * 1024)
	send_arena_alloc_err := virtual.arena_init_buffer(&send_arena, send_arena_buffer)
	assert(send_arena_alloc_err == .None)
	send_arena_allocator := virtual.arena_allocator(&send_arena)
	defer delete(send_arena_buffer)

	// TODO(Thomas): Pass in the Arena instead
	send_stream := proto.create_send_stream(
		send_arena_allocator,
		"127.0.0.1",
		8000,
		"127.0.0.1",
		8001,
	)
	defer proto.destroy_send_stream(&send_stream)

	// TODO(Thomas): Split more of this functionality out
	for {
		test_packet := proto.random_test_packet(-1000, 1000)

		test_packet_buffer: []u32

		test_packet_type_ser := proto.Test_Packet_Type.A
		switch ty in test_packet {
		case proto.Test_Packet_A:
			test_packet_type_ser = .A
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		case proto.Test_Packet_B:
			test_packet_type_ser = .B
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		case proto.Test_Packet_C:
			test_packet_type_ser = .C
			test_packet_buffer = make([]u32, size_of(ty) / size_of(u32), context.allocator)
		}

		log.info("Send test packet type", test_packet_type_ser)
		log.info("Send test packet type (u32):", u32(test_packet_type_ser))

		defer delete(test_packet_buffer)

		test_packet_writer := proto.create_writer(test_packet_buffer)

		serialize_test_packet_ok := proto.serialize_test_packet(&test_packet_writer, test_packet)
		assert(serialize_test_packet_ok)

		flush_bits_ok := proto.flush_bits(&test_packet_writer)

		proto.enqueue_packet(
			&send_stream,
			proto.QOS.Best_Effort,
			u32(test_packet_type_ser),
			proto.convert_word_slice_to_byte_slice(test_packet_writer.buffer),
		)

		proto.process_send_stream(&send_stream)

		// CONTINUE HERE: When packets are dropped / out of sync, this will return
		// false and we break out and trying to process empty buffer. Also probably
		// lots of other things that are broken and buggy
		for proto.recv_packet(&recv_stream) {}

		packet_data, packet_data_ok := proto.process_realtime_packet_buffer(
			recv_stream.realtime_packet_buffer,
			context.allocator,
		)

		assert(packet_data_ok)
		defer delete(packet_data.data, context.allocator)

		// TODO(Thomas): Do this here or in the process_realtime_packet_buffer procedure?
		// If the length of the packet data is 0, we know that it doesn't make sense to deserialize it.
		// Question is whether this is the right place to do this, or maybe packet_data_ok should be false
		// in this case, or introduce an error type for it.
		if len(packet_data.data) == 0 do continue

		test_packet_type_des := proto.Test_Packet_Type(packet_data.type)

		log.info("Recv test packet_type: ", test_packet_type_des)

		test_packet_reader := proto.create_reader(
			proto.convert_byte_slice_to_word_slice(packet_data.data),
		)

		des_test_packet: proto.Test_Packet
		des_test_packet_ok := false
		switch test_packet_type_des {
		case .A:
			des_test_packet, des_test_packet_ok = proto.deserialize_test_packet_a(
				&test_packet_reader,
			)
			if !des_test_packet_ok do log.error("failed to deserialize test packet a")
			assert(des_test_packet_ok, "failed to deserialize test packet a")
		case .B:
			des_test_packet, des_test_packet_ok = proto.deserialize_test_packet_b(
				&test_packet_reader,
			)
			if !des_test_packet_ok do log.error("failed to deserialize test packet b")
			assert(des_test_packet_ok, "failed to deserialize test packet b")
		case .C:
			des_test_packet, des_test_packet_ok = proto.deserialize_test_packet_c(
				&test_packet_reader,
			)
			if !des_test_packet_ok do log.error("failed to deserialize test packet b")
			assert(des_test_packet_ok)
		}


		assert(des_test_packet == test_packet)
	}
}
