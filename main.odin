package main

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"

import proto "protocol"

//MAX_OUTGOING_PACKETS :: 16
//
//Packet_Queue :: struct {
//	current_idx: u32,
//	packets:     [MAX_OUTGOING_PACKETS]Packet,
//}
//
//enqueue_packet :: proc(packet_queue: ^Packet_Queue, packet: Packet) -> bool {
//	if packet_queue.current_idx >= MAX_OUTGOING_PACKETS {
//		return false
//	}
//	packet_queue.packets[packet_queue.current_idx] = packet
//	packet_queue.current_idx += 1
//	return true
//}
//
//// Add more packet types, this is high-level packets??
//Packet :: union {
//	proto.Test_Packet_B,
//}
//
//Packet_Stream :: struct {
//	packet_writer:   proto.Bit_Writer,
//	fragment_writer: proto.Bit_Writer,
//	packet_queue:    ^Packet_Queue,
//}
//
//Packet_Read_Stream :: struct {
//	packet_reader:   proto.Bit_Reader,
//	fragment_reader: proto.Bit_Reader,
//	packet_queue:    ^Packet_Queue,
//	sequence_buffer: ^proto.Sequence_Buffer,
//}
//
//create_packet_read_stream :: proc(
//	allocator := context.allocator,
//) -> Packet_Read_Stream {
//	packet_buffer := make([]u32, 1_000_000, allocator)
//	packet_reader := proto.create_reader(packet_buffer)
//
//	fragment_buffer := make([]u32, 1_000_000, allocator)
//	fragment_reader := proto.create_reader(fragment_buffer)
//
//	packet_queue := new(Packet_Queue, allocator)
//	sequence_buffer := new(proto.Sequence_Buffer, allocator)
//	proto.init_sequence_buffer(sequence_buffer)
//
//	return Packet_Read_Stream {
//		packet_reader,
//		fragment_reader,
//		packet_queue,
//		sequence_buffer,
//	}
//}
//
//Network_Queue :: struct {
//	data_queue: queue.Queue([]u8),
//	allocator:  runtime.Allocator,
//}
//
//create_packet_stream :: proc(allocator := context.allocator) -> Packet_Stream {
//	packet_buffer := make([]u32, 1_000_000, allocator)
//	packet_writer := proto.create_writer(packet_buffer)
//
//	fragment_buffer := make([]u32, 1_000_000, allocator)
//	fragment_writer := proto.create_writer(fragment_buffer)
//
//	packet_queue := new(Packet_Queue, allocator)
//
//	return Packet_Stream{packet_writer, fragment_writer, packet_queue}
//}
//
//
//// TODO(Thomas): Error handling
//send_stream :: proc(
//	packet_stream: ^Packet_Stream,
//	network_queue: ^Network_Queue,
//	allocator := context.allocator,
//) {
//	for i in 0 ..< packet_stream.packet_queue.current_idx {
//		// 1. Serialize the packet
//		assert(
//			serialize_packet(
//				&packet_stream.packet_writer,
//				packet_stream.packet_queue.packets[i],
//			),
//		)
//
//		// 2. Get the packet bytes
//		packet_bytes := proto.convert_word_slice_to_byte_slice(
//			packet_stream.packet_writer.buffer[0:packet_stream.packet_writer.word_index],
//		)
//
//
//		// 3. Check if the length of the packet is larger than MTU, meaning that we need to split it
//		// into fragments
//		if len(packet_bytes) > proto.MTU {
//			log.infof("len(packet_bytes) is %v", len(packet_bytes))
//
//			fragments := proto.split_packet_into_fragments(
//				u16(i),
//				packet_bytes,
//			)
//
//			// 4. Write all the fragments into Network_Queue
//			for fragment in fragments {
//				assert(
//					proto.serialize_fragment_packet(
//						&packet_stream.fragment_writer,
//						fragment,
//					),
//				)
//
//				assert(proto.flush_bits(&packet_stream.fragment_writer))
//
//				fragment_bytes := proto.convert_word_slice_to_byte_slice(
//					packet_stream.fragment_writer.buffer[0:packet_stream.fragment_writer.word_index],
//				)
//
//				fragment_bytes_len := len(fragment_bytes)
//
//				network_fragment_bytes := make(
//					[]u8,
//					fragment_bytes_len,
//					network_queue.allocator,
//				)
//
//				mem.copy(
//					&network_fragment_bytes[0],
//					&fragment_bytes[0],
//					fragment_bytes_len,
//				)
//
//				// memcopy the bytes from the writer
//				ok, err := queue.push_back(
//					&network_queue.data_queue,
//					network_fragment_bytes,
//				)
//
//				assert(ok)
//				assert(err == nil)
//
//				proto.reset_writer(&packet_stream.fragment_writer)
//			}
//
//			proto.reset_writer(&packet_stream.packet_writer)
//
//		} else {
//			// If not just write the packet bytes directly into the Network_Queue
//		}
//	}
//}
//
//// TODO(Thomas): Can't know which Packet Type this is before reading PacketHeader
//// Just going to assume its a fragment for now, but when we start to support multiple
//// packet types we need to do that.
//receive_stream :: proc(
//	packet_read_stream: ^Packet_Read_Stream,
//	network_queue: ^Network_Queue,
//	allocator := context.allocator,
//) {
//	for byte_slice in queue.pop_front_safe(&network_queue.data_queue) {
//		assert(len(byte_slice) != 0)
//
//		// Continue here, this triggers assert
//		assert(
//			proto.process_packet(
//				packet_read_stream.sequence_buffer,
//				byte_slice,
//				allocator,
//			),
//		)
//
//	}
//
//	packet_data, ok := proto.receive_packet_fragments(
//		packet_read_stream.sequence_buffer,
//		0,
//		allocator,
//	)
//
//	assert(ok)
//	packet_data_len := len(packet_data)
//	assert(packet_data_len == size_of(u32) * 2048)
//
//	mem.copy(
//		&packet_read_stream.packet_reader.buffer[0],
//		&(packet_data)[0],
//		packet_data_len,
//	)
//
//	des_test_packet_b, des_test_packet_b_ok := proto.deserialize_test_packet_b(
//		&packet_read_stream.packet_reader,
//	)
//
//	assert(des_test_packet_b_ok)
//
//	assert(enqueue_packet(packet_read_stream.packet_queue, des_test_packet_b))
//
//	free_all(network_queue.allocator)
//}
//
//serialize_packet :: proc(
//	bit_writer: ^proto.Bit_Writer,
//	packet: Packet,
//) -> bool {
//	switch p in packet {
//	case proto.Test_Packet_B:
//		if !proto.serialize_test_packet_b(bit_writer, p) {
//			return false
//		}
//
//		if !proto.flush_bits(bit_writer) {
//			return false
//		}
//	}
//	return true
//}

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

	//send_memory := make([]u8, 10_000_000)
	//defer delete(send_memory)
	//send_arena := mem.Arena{}
	//mem.arena_init(&send_arena, send_memory)
	//send_arena_allocator := mem.arena_allocator(&send_arena)

	//recv_memory := make([]u8, 10_000_000)
	//defer delete(recv_memory)
	//recv_arena := mem.Arena{}
	//mem.arena_init(&recv_arena, recv_memory)
	//recv_arena_allocator := mem.arena_allocator(&recv_arena)

	//network_memory := make([]u8, 10_000_000)
	//defer delete(network_memory)
	//network_arena := mem.Arena{}
	//mem.arena_init(&network_arena, network_memory)
	//network_arena_allocator := mem.arena_allocator(&network_arena)

	//network_queue := Network_Queue {
	//	allocator = network_arena_allocator,
	//}

	//err := queue.init(
	//	&network_queue.data_queue,
	//	MAX_OUTGOING_PACKETS,
	//	network_arena_allocator,
	//)
	//assert(err == nil)

	//send_packet_stream := create_packet_stream(send_arena_allocator)

	////for i in 0 ..< MAX_OUTGOING_PACKETS {
	////	test_packet := proto.random_test_packet_b()
	////	assert(enqueue_packet(send_packet_stream.packet_queue, test_packet))
	////}

	//test_packet := proto.random_test_packet_b()
	//assert(enqueue_packet(send_packet_stream.packet_queue, test_packet))

	//send_stream(&send_packet_stream, &network_queue, send_arena_allocator)

	//receive_packet_stream := create_packet_read_stream(recv_arena_allocator)

	//receive_stream(
	//	&receive_packet_stream,
	//	&network_queue,
	//	recv_arena_allocator,
	//)

	//received_packet := receive_packet_stream.packet_queue.packets[0]

	//assert(test_packet == received_packet)
}
