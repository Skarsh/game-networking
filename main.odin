package main

import "core:fmt"
import "core:log"
import "core:mem"

import proto "protocol"

main :: proc() {
	using proto

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

	sequence_buffer := Sequence_Buffer{}
	init_sequence_buffer(&sequence_buffer)

	// Simple red thread test for packet fragmentation and reassembly, no network related stuff yet.
	// 
	// Sending side: 
	// Make a packet that is bigger than the max packet size, so it has to be
	// split up into packet fragments. Write a simple split_packet_into_fragments procedure.
	// Then for each packet fragment write serialize them and write each of them into a buffer.
	//
	// Receiving side: 
	// Deserialize the byte buffer into an array of fragment packets
	// Utilize the sequence buffer here
	// Finally reconstruct the original packet from the fragment packets.

	// Next step is to do this for multiple large packets.
	// Step after that is to do it over the network

	buffer := make([]u32, 2048, context.allocator)
	defer delete(buffer)
	writer := create_writer(buffer)

	// Sending
	test_packet := proto.random_test_packet()
	log.infof("test_packet size: %v", size_of(test_packet))
	if size_of(test_packet) > proto.MTU {
		// We need to split this into fragments
		log.info("Splitting packet into fragments")
		assert(serialize_test_packet(&writer, test_packet))
		assert(flush_bits(&writer))

		packet_data := convert_word_slice_to_byte_slice(writer.buffer)
		assert(len(packet_data) == 2048 * size_of(u32))
		words := convert_byte_slice_to_word_slice(packet_data)

		// Not relevant for this exact test, but good for ensuring that de-/serialize works
		reader := create_reader(words)
		packet, des_ok := desserialize_test_packet(&reader)
		assert(des_ok)
		assert(test_packet == packet)

		num_fragments: u32 = 0
		fragments_data := split_packet_into_fragments(
			0,
			packet_data,
			&num_fragments,
			context.allocator,
		)
		defer delete(fragments_data)

		// TODO(Thomas): The continuation here is now to serialize all the fragments
		// Then deserialize them and recreate the original TestPacket.
		// Also think about the Bit_Writer here, should it be two different ones for the TestPacket
		// and the fragments? If not, its needs to be reset before writing the fragments no?
	}
}
