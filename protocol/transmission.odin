package protocol

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"

MAX_OUTGOING_PACKETS :: 8

Send_Stream :: struct {
	allocator:        runtime.Allocator,
	queue:            queue.Queue([]u8),
	socket:           net.UDP_Socket,
	endpoint:         net.Endpoint,
	current_sequence: u16,
}

create_send_stream :: proc(
	allocator: runtime.Allocator,
	address: string,
	port: int,
	endpoint_address: string,
	endpoint_port: int,
) -> Send_Stream {
	packet_queue := queue.Queue([]u8){}
	queue.init(&packet_queue, MAX_OUTGOING_PACKETS, allocator)

	address := net.parse_address(address)
	assert(address != nil)

	socket, bound_socket_err := net.make_bound_udp_socket(address, port)
	assert(bound_socket_err == nil)

	endpoint_string := fmt.tprintf("%s:%d", endpoint_address, endpoint_port)

	endpoint, endpoint_ok := net.parse_endpoint(endpoint_string)
	assert(endpoint_ok)

	return Send_Stream {
		allocator = allocator,
		queue = packet_queue,
		socket = socket,
		endpoint = endpoint,
		current_sequence = 0,
	}
}

free_send_stream :: proc(send_stream: ^Send_Stream) {
	free_all(send_stream.allocator)
}

// TODO(Thomas): Calculate crc32 properly
create_net_packet :: proc(
	allocator: runtime.Allocator,
	sequence: u16,
	qos: QOS,
	packet_type: u32,
	is_fragment: bool,
	data: []u8,
) -> []u8 {
	data_size: u32 = u32(len(data))
	assert(data_size > 0)
	assert(data_size <= MTU)
	packet_header := Packet_Header {
		crc32       = 42,
		qos         = u32(qos),
		packet_type = packet_type,
		data_length = data_size,
		sequence    = sequence,
		is_fragment = is_fragment,
	}

	packet_buffer := make([]u32, (size_of(Packet_Header) + data_size) / size_of(u32), allocator)
	packet_writer := create_writer(packet_buffer)

	serialize_packet_ok := serialize_packet_from_header_and_byte_slice(
		&packet_writer,
		packet_header,
		data,
	)
	assert(serialize_packet_ok)

	flush_ok := flush_bits(&packet_writer)
	assert(flush_ok)

	return convert_word_slice_to_byte_slice(packet_writer.buffer)
}

enqueue_packet :: proc(send_stream: ^Send_Stream, qos: QOS, packet_type: u32, packet_data: []u8) {
	assert(len(packet_data) > 0)
	assert(len(packet_data) <= MAX_PACKET_SIZE)

	if len(packet_data) > MTU {
		// Larger than MTU, so we need to split it into fragments
		fragments := split_packet_into_fragments(packet_data, send_stream.allocator)

		for fragment in fragments {
			fragment_buffer := make(
				[]u32,
				(size_of(Fragment_Header) + len(fragment.data)) / size_of(u32),
				send_stream.allocator,
			)

			fragment_writer := create_writer(fragment_buffer)
			serialize_fragment_ok := serialize_fragment(&fragment_writer, fragment)
			assert(serialize_fragment_ok)

			packet_bytes := create_net_packet(
				send_stream.allocator,
				send_stream.current_sequence,
				qos,
				packet_type,
				true,
				convert_word_slice_to_byte_slice(fragment_writer.buffer),
			)

			push_ok, push_err := queue.push_back(&send_stream.queue, packet_bytes)
			assert(push_ok)
			assert(push_err == nil)
		}

	} else {
		// The packet data is small enough to fit into a single network packet
		packet_bytes := create_net_packet(
			send_stream.allocator,
			send_stream.current_sequence,
			qos,
			packet_type,
			false,
			packet_data,
		)
		push_ok, push_err := queue.push_back(&send_stream.queue, packet_bytes)
		assert(push_ok)
		assert(push_err == nil)
	}

	send_stream.current_sequence += 1
}

process_send_stream :: proc(send_stream: ^Send_Stream) {
	for packet_bytes in queue.pop_front_safe(&send_stream.queue) {

		bytes_written, err := net.send_udp(send_stream.socket, packet_bytes, send_stream.endpoint)

		log.info("bytes_written: ", bytes_written)
		assert(err == nil)
	}
}

Realtime_Packet_Buffer :: struct {}

init_realtime_packet_buffer :: proc(packet_buffer: ^Realtime_Packet_Buffer) {}

// NOTE(Thomas): Think about allocation and how to do them well for the Realtime Packet Buffer
Recv_Stream :: struct {
	persistent_allocator:   runtime.Allocator,
	temp_allocator:         runtime.Allocator,
	realtime_packet_buffer: Realtime_Packet_Buffer,
	socket:                 net.UDP_Socket,
	net_packet_buf:         [MTU]u8,
}

create_recv_stream :: proc(
	persistent_allocator: runtime.Allocator,
	temp_allocator: runtime.Allocator,
	address: string,
	port: int,
) -> Recv_Stream {
	realtime_packet_buffer := Realtime_Packet_Buffer{}
	init_realtime_packet_buffer(&realtime_packet_buffer)

	address := net.parse_address(address)
	assert(address != nil)

	socket, bound_socket_err := net.make_bound_udp_socket(address, port)
	assert(bound_socket_err == nil)

	// make the socket non-blocking
	blocking_err := net.set_blocking(socket, false)
	assert(blocking_err == nil)

	return Recv_Stream {
		persistent_allocator = persistent_allocator,
		temp_allocator = temp_allocator,
		realtime_packet_buffer = realtime_packet_buffer,
		socket = socket,
	}
}

recv_packet :: proc(recv_stream: ^Recv_Stream) -> ([]u8, bool) {
	bytes_read, remote_endpoint, recv_err := net.recv_udp(
		recv_stream.socket,
		recv_stream.net_packet_buf[:],
	)
	assert(recv_err == nil)
	if bytes_read == 0 {
		return nil, false
	}

	packet_reader := create_reader(convert_byte_slice_to_word_slice(recv_stream.net_packet_buf[:]))

	packet, packet_ok := deserialize_packet(&packet_reader, recv_stream.persistent_allocator)
	assert(packet_ok)

	log.info("packet: ", packet)

	return packet.data, true
}
