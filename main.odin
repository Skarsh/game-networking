package main

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"

import proto "protocol"

// Receiver side needs to do the following steps
// 1. Recv bytes from udp socket
// 2. pass the data to the process_packet
// 
// So we need a data structure that holds the reader, Packet_Buffer

Receiver :: struct {
	socket:        net.UDP_Socket,
	packet_buffer: proto.Packet_Buffer,
	allocator:     runtime.Allocator,
}

create_receiver :: proc(allocator: runtime.Allocator) -> Receiver {
	address := net.parse_address("127.0.0.1")
	socket, bound_socket_err := net.make_bound_udp_socket(address, 8001)
	assert(bound_socket_err == nil)

	blocking_err := net.set_blocking(socket, false)
	assert(blocking_err == nil)

	packet_buffer := proto.Packet_Buffer{}
	proto.init_packet_buffer(&packet_buffer)

	receiver := Receiver {
		socket        = socket,
		packet_buffer = packet_buffer,
		allocator     = allocator,
	}

	return receiver
}

recv_packets :: proc(receiver: ^Receiver) {
	buf := make([]u8, proto.MAX_PACKET_SIZE, receiver.allocator)
	bytes_read, remote_endpoint, recv_err := net.recv_udp(receiver.socket, buf)
	assert(recv_err == nil)
	if bytes_read == 0 {
		return
	}

	process_ok := proto.process_packet(&receiver.packet_buffer, buf, receiver.allocator)
	assert(process_ok)

	log.info("packet_buffer: ", receiver.packet_buffer)
}

Packet_Stream :: struct {
	persistent_allocator: runtime.Allocator,
	temp_allocator:       runtime.Allocator,
	current_sequence:     u32,
	test_packet_writer:   proto.Bit_Writer,
	packet_writer:        proto.Bit_Writer,
	fragment_writer:      proto.Bit_Writer,
	packet_queue:         queue.Queue(proto.Test_Packet),
	socket:               net.UDP_Socket,
}

create_packet_stream :: proc(
	persistent_allocator: runtime.Allocator,
	temp_allocator: runtime.Allocator,
) -> Packet_Stream {

	current_sequence: u32 = 0

	packet_queue := queue.Queue(proto.Test_Packet){}
	queue.init(&packet_queue, 16, persistent_allocator)

	address := net.parse_address("127.0.0.1")
	socket, bound_socket_err := net.make_bound_udp_socket(address, 8000)
	assert(bound_socket_err == nil)

	return Packet_Stream {
		persistent_allocator = persistent_allocator,
		temp_allocator = temp_allocator,
		current_sequence = current_sequence,
		socket = socket,
	}
}

free_packet_stream_temp :: proc(packet_stream: ^Packet_Stream) {
	free_all(packet_stream.temp_allocator)
}

enqueue_packet :: proc(packet: proto.Test_Packet, packet_stream: ^Packet_Stream) {
	ok, err := queue.push_back(&packet_stream.packet_queue, packet)
	assert(ok)
	assert(err == nil)
}

process_and_send_stream :: proc(packet_stream: ^Packet_Stream) {
	endpoint, endpoint_ok := net.parse_endpoint("127.0.0.1:8001")
	assert(endpoint_ok)
	for test_packet in queue.pop_front_safe(&packet_stream.packet_queue) {

		// 2048 size_of(u32) == 8192 bytes is the worst case size of the test packet
		test_packet_writer_buffer := make([]u32, 2048, packet_stream.temp_allocator)
		packet_stream.test_packet_writer = proto.create_writer(test_packet_writer_buffer)

		serialize_test_packet_ok := proto.serialize_test_packet(
			&packet_stream.test_packet_writer,
			test_packet,
		)
		assert(serialize_test_packet_ok)

		flush_test_packet_bits_ok := proto.flush_bits(&packet_stream.test_packet_writer)
		assert(flush_test_packet_bits_ok)

		packet_data_size := proto.get_writer_bytes_written(packet_stream.test_packet_writer)
		log.info("packet_data_size: ", packet_data_size)
		if packet_data_size > proto.MTU {
			log.info("splitting into fragments")

			// TODO(Thomas): Make this less prone to failure by having to divide by size_of(u32)
			fragments := proto.split_packet_into_fragments(
				u16(packet_stream.current_sequence),
				proto.convert_word_slice_to_byte_slice(
					packet_stream.test_packet_writer.buffer[:packet_data_size / size_of(u32)],
				),
				packet_stream.temp_allocator,
			)

			num_fragments := len(fragments)
			assert(num_fragments == 8)

			for fragment in fragments {
				fragment_data_size := (size_of(proto.Fragment_Header) + proto.MAX_FRAGMENT_SIZE)

				fragment_writer_buffer := make([]u32, fragment_data_size / size_of(u32))
				packet_stream.fragment_writer = proto.create_writer(fragment_writer_buffer)

				serialize_fragment_ok := proto.serialize_fragment(
					&packet_stream.fragment_writer,
					fragment,
				)
				assert(serialize_fragment_ok)

				flush_fragment_bits_ok := proto.flush_bits(&packet_stream.fragment_writer)
				assert(flush_fragment_bits_ok)

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
					data_length = u32(fragment_data_size),
					sequence    = u16(packet_stream.current_sequence),
					is_fragment = true,
				}

				packet_writer_buffer_size := (size_of(proto.Packet_Header) + fragment_data_size)

				packet_writer_buffer := make(
					[]u32,
					packet_writer_buffer_size / size_of(u32),
					packet_stream.temp_allocator,
				)

				packet_stream.packet_writer = proto.create_writer(packet_writer_buffer)

				// TODO(Thomas): Make this less prone to failure by having to divide by size_of(u32)
				serialize_packet_ok := proto.serialize_packet_from_header_and_byte_slice(
					&packet_stream.packet_writer,
					packet_header,
					proto.convert_word_slice_to_byte_slice(
						packet_stream.fragment_writer.buffer[0:fragment_data_size / size_of(u32)],
					),
				)

				assert(serialize_packet_ok)

				flush_packet_bits_ok := proto.flush_bits(&packet_stream.packet_writer)
				assert(flush_packet_bits_ok)

				proto.reset_writer(&packet_stream.fragment_writer)
				proto.reset_writer(&packet_stream.packet_writer)

				// TODO(Thomas): This is just for testing, move to proper place.
				bytes_written, err := net.send_udp(
					packet_stream.socket,
					proto.convert_word_slice_to_byte_slice(packet_stream.packet_writer.buffer),
					endpoint,
				)

				log.info("bytes_written: ", bytes_written)
				assert(err == nil)
			}

		} else {
			packet_writer_buffer := make(
				[]u32,
				(size_of(proto.Packet_Header) + packet_data_size) / size_of(u32),
				packet_stream.temp_allocator,
			)

			packet_stream.packet_writer = proto.create_writer(packet_writer_buffer)


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
				sequence    = u16(packet_stream.current_sequence),
				is_fragment = false,
			}

			// TODO(Thomas): Make this less prone to failure by having to divide by size_of(u32)
			serialize_packet_ok := proto.serialize_packet_from_header_and_byte_slice(
				&packet_stream.packet_writer,
				packet_header,
				proto.convert_word_slice_to_byte_slice(
					packet_stream.test_packet_writer.buffer[0:packet_data_size / size_of(u32)],
				),
			)

			assert(serialize_packet_ok)

			flush_packet_bits_ok := proto.flush_bits(&packet_stream.packet_writer)
			assert(flush_packet_bits_ok)
		}

		// Ready to send to socket
		// TODO(Thomas): This is just for testing, move to proper place.
		bytes_written, err := net.send_udp(
			packet_stream.socket,
			proto.convert_word_slice_to_byte_slice(packet_stream.packet_writer.buffer),
			endpoint,
		)

		log.info("bytes_written: ", bytes_written)
		assert(err == nil)

		// This needs to wrap around then going above 65535 (math.max(u16))
		packet_stream.current_sequence += 1

		free_packet_stream_temp(packet_stream)
	}
}

// Outline of packet fragmentation and re-assembly long running tests
// In a for loop:
// 1. Create random packet type
// 2. Put the packet on a queue 
// 3. Serialize the packet
// 4. Send the packet over udp
// 5. Recv packet on udp
// 6. Process the packet
// 7. Receive fragments? We should really rename this
// 8. Compare sent and reassembled packet for equality
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

	// Initializing
	// TODO(Thomas): Properly figure out how to use allocators here
	packet_stream := create_packet_stream(context.allocator, context.temp_allocator)
	defer free_all(context.temp_allocator)

	lo: f32 = -1000
	hi: f32 = 1000

	// TODO(Thomas): Another allocator here maybe?
	receiver := create_receiver(context.allocator)

	for {
		// Step 1: Create random test packet
		test_packet := proto.random_test_packet(lo, hi)

		// Step 2: Put the test packet on the packet stream
		enqueue_packet(test_packet, &packet_stream)

		// Step 3: Process and send packets
		process_and_send_stream(&packet_stream)

		// Step 4: Recv packets
		recv_packets(&receiver)
	}

}
