package main

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"

import proto "protocol"

MAX_OUTGOING_PACKETS :: 16

Packet_Queue :: struct {
	current_idx: u32,
	packets:     [MAX_OUTGOING_PACKETS]proto.Packet,
}

enqueue_packet :: proc(packet_queue: ^Packet_Queue, packet: proto.Packet) -> bool {
	if packet_queue.current_idx >= MAX_OUTGOING_PACKETS {
		return false
	}
	packet_queue.packets[packet_queue.current_idx] = packet
	packet_queue.current_idx += 1
	return true
}


Packet_Stream :: struct {
	packet_writer:   proto.Bit_Writer,
	fragment_writer: proto.Bit_Writer,
	packet_queue:    ^Packet_Queue,
}


create_packet_stream :: proc(allocator := context.allocator) -> Packet_Stream {
	packet_buffer := make([]u32, 1_000_000, allocator)
	packet_writer := proto.create_writer(packet_buffer)

	fragment_buffer := make([]u32, 1_000_000, allocator)
	fragment_writer := proto.create_writer(fragment_buffer)

	packet_queue := new(Packet_Queue, allocator)

	return Packet_Stream{packet_writer, fragment_writer, packet_queue}
}


// TODO(Thomas): What about tracking for 
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

	packet_buffer := proto.Packet_Buffer{}
	proto.init_packet_buffer(&packet_buffer)

	lo: f32 = -1000
	hi: f32 = 1000

	test_packet := proto.random_test_packet(lo, hi)

	// 2048 size_of(u32) == 8192 bytes is the worst case size of the test packet
	test_packet_writer_buffer := make([]u32, 2048, context.temp_allocator)
	defer free_all(context.temp_allocator)
	test_packet_writer := proto.create_writer(test_packet_writer_buffer)
	assert(proto.serialize_test_packet(&test_packet_writer, test_packet))
	assert(proto.flush_bits(&test_packet_writer))

	packet_data_size := proto.get_writer_bytes_written(test_packet_writer)
	log.info("packet_data_size: ", packet_data_size)
	if packet_data_size > proto.MTU {
		// split
		log.info("splitting into fragments")

		fragments := proto.split_packet_into_fragments(
			u16(packet_buffer.current_sequence),
			proto.convert_word_slice_to_byte_slice(test_packet_writer.buffer),
			context.temp_allocator,
		)

		num_fragments := len(fragments)
		assert(num_fragments == 8)

		for fragment in fragments {
			packet_data_size := (size_of(proto.Fragment_Header) + proto.MAX_FRAGMENT_SIZE)
			fragment_writer_buffer := make(
				[]u32,
				packet_data_size / size_of(u32),
				context.temp_allocator,
			)

			fragment_writer := proto.create_writer(fragment_writer_buffer)

			assert(proto.serialize_fragment(&fragment_writer, fragment))

			assert(proto.flush_bits(&fragment_writer))

			packet_writer_buffer := make(
				[]u32,
				(size_of(proto.Packet_Header) + packet_data_size) / size_of(u32),
				context.temp_allocator,
			)

			packet_writer := proto.create_writer(packet_writer_buffer)

			packet_type: proto.Packet_Type
			switch packet in test_packet {
			case proto.Test_Packet_A:
				packet_type = proto.Packet_Type.Test_A
			case proto.Test_Packet_B:
				packet_type = proto.Packet_Type.Test_B
			case proto.Test_Packet_C:
				packet_type = proto.Packet_Type.Test_C
			}

			packet_header := proto.Packet_Header {
				crc32       = 42,
				packet_type = u32(packet_type),
				data_length = u32(packet_data_size),
				sequence    = 0,
				is_fragment = true,
			}

			assert(
				proto.serialize_packet_from_header_and_byte_slice(
					&packet_writer,
					packet_header,
					proto.convert_word_slice_to_byte_slice(fragment_writer.buffer),
				),
			)

			assert(proto.flush_bits(&packet_writer))

			assert(
				proto.process_packet(
					&packet_buffer,
					proto.convert_word_slice_to_byte_slice(packet_writer.buffer),
					context.temp_allocator,
				),
			)
		}


	} else {
		// We have the serialized bytes, make packet
		packet_writer_buffer := make(
			[]u32,
			(size_of(proto.Packet_Header) + packet_data_size) / size_of(u32),
			context.temp_allocator,
		)

		packet_writer := proto.create_writer(packet_writer_buffer)

		packet_type: proto.Packet_Type
		switch packet in test_packet {
		case proto.Test_Packet_A:
			packet_type = proto.Packet_Type.Test_A
		case proto.Test_Packet_B:
			packet_type = proto.Packet_Type.Test_B
		case proto.Test_Packet_C:
			packet_type = proto.Packet_Type.Test_C
		}

		packet_header := proto.Packet_Header {
			crc32       = 42,
			packet_type = u32(packet_type),
			data_length = u32(packet_data_size),

			// TODO(Thomas): Need a way to get the actual sequence, probably from calling a procedure like
			// advance_sequence(packet_buffer)
			sequence    = 0,
			is_fragment = false,
		}

		assert(
			proto.serialize_packet_from_header_and_byte_slice(
				&packet_writer,
				packet_header,
				proto.convert_word_slice_to_byte_slice(
					test_packet_writer.buffer[0:packet_data_size / size_of(u32)],
				),
			),
		)

		assert(proto.flush_bits(&packet_writer))

		// Ready to send
	}
}
