package protocol

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"

MAX_FRAGMENTS_PER_PACKET :: 256
MAX_FRAGMENT_SIZE :: 1024
MAX_PACKET_SIZE :: MAX_FRAGMENTS_PER_PACKET * MAX_FRAGMENT_SIZE

// Used to represent empty entries since it cannot occur
// by 16 bit sequence numbers.
ENTRY_SENTINEL_VALUE :: 0xFFFF_FFFF

MAX_ENTRIES :: 8

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
	}

	packet_size_bytes := size_of(Packet_Header) + data_size
	packet_buffer := make([]u32, packet_size_bytes / size_of(u32), allocator)
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

// TODO(Thomas): Make sure the sequence number wraps around
enqueue_packet :: proc(send_stream: ^Send_Stream, qos: QOS, packet_type: u32, packet_data: []u8) {
	assert(len(packet_data) > 0)
	assert(len(packet_data) <= MAX_PACKET_SIZE)

	log.info("len(packet_data): ", len(packet_data))

	switch qos {
	case .Best_Effort:
		fragments := split_packet_into_fragments(packet_data, send_stream.allocator)

		for fragment in fragments {
			log.info("len(fragment.data): ", len(fragment.data))
			fragment_buffer := make(
				[]u32,
				(size_of(Fragment_Header) + len(fragment.data)) / size_of(u32),
				send_stream.allocator,
			)

			fragment_writer := create_writer(fragment_buffer)
			serialize_fragment_ok := serialize_fragment(&fragment_writer, fragment)
			assert(serialize_fragment_ok)

			flush_ok := flush_bits(&fragment_writer)
			assert(flush_ok)

			packet_bytes := create_net_packet(
				send_stream.allocator,
				send_stream.current_sequence,
				qos,
				packet_type,
				convert_word_slice_to_byte_slice(fragment_writer.buffer),
			)

			push_ok, push_err := queue.push_back(&send_stream.queue, packet_bytes)
			assert(push_ok)
			assert(push_err == nil)
		}

	case .Reliable:
	}

	send_stream.current_sequence += 1
}

process_send_stream :: proc(send_stream: ^Send_Stream) {
	for packet_bytes in queue.pop_front_safe(&send_stream.queue) {

		bytes_written, err := net.send_udp(send_stream.socket, packet_bytes, send_stream.endpoint)

		log.info("bytes_written: ", bytes_written)
		assert(err == nil)
	}

	free_send_stream(send_stream)
}

Fragment_Data :: struct {
	data_length: int,
	data:        [MAX_FRAGMENT_SIZE]u8,
}

Fragment_Entry :: struct {
	num_fragments:      u8,
	received_fragments: u8,
	fragments:          [MAX_FRAGMENTS_PER_PACKET]Fragment_Data,
}

Realtime_Packet_Entry :: struct {
	packet_type: u32,
	sequence:    u32,
	entry:       Fragment_Entry,
}

Realtime_Packet_Buffer :: struct {
	current_sequence: u32,
	entries:          [MAX_ENTRIES]Realtime_Packet_Entry,
}

get_realtime_packet_entry :: proc(
	idx: int,
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
) -> (
	^Realtime_Packet_Entry,
	bool,
) {
	if idx < 0 || idx >= len(realtime_packet_buffer.entries) {
		return nil, false
	}

	return &realtime_packet_buffer.entries[idx], true
}

init_realtime_packet_buffer :: proc(packet_buffer: ^Realtime_Packet_Buffer) {
	for idx in 0 ..< len(packet_buffer.entries) {
		entry, entry_ok := get_realtime_packet_entry(idx, packet_buffer)
		assert(entry_ok)
		entry.sequence = ENTRY_SENTINEL_VALUE
	}
}

// NOTE(Thomas): Think about allocation and how to do them well for the Realtime Packet Buffer
Recv_Stream :: struct {
	persistent_allocator:   runtime.Allocator,
	temp_allocator:         runtime.Allocator,
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
	socket:                 net.UDP_Socket,
	net_packet_buf:         [MTU]u8,
}

recv_stream_free_temp_allocator :: proc(recv_stream: ^Recv_Stream) {
	free_all(recv_stream.temp_allocator)
}

create_recv_stream :: proc(
	persistent_allocator: runtime.Allocator,
	temp_allocator: runtime.Allocator,
	address: string,
	port: int,
) -> Recv_Stream {
	realtime_packet_buffer := new(Realtime_Packet_Buffer, persistent_allocator)
	init_realtime_packet_buffer(realtime_packet_buffer)

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

destroy_recv_stream :: proc(recv_stream: ^Recv_Stream) {
	free(recv_stream.realtime_packet_buffer, recv_stream.persistent_allocator)
}

recv_packet :: proc(recv_stream: ^Recv_Stream) {
	bytes_read, remote_endpoint, recv_err := net.recv_udp(
		recv_stream.socket,
		recv_stream.net_packet_buf[:],
	)
	assert(recv_err == nil)
	// TODO(Thomas): Return false or some error type here?
	if bytes_read == 0 {
		return
	}

	ok := process_packet(recv_stream.net_packet_buf[:bytes_read], recv_stream)
	assert(ok)
}

process_packet :: proc(packet_data: []u8, recv_stream: ^Recv_Stream) -> bool {
	assert(len(packet_data) > 0)
	assert(len(packet_data) <= MTU)

	log.info("len(packet_data): ", len(packet_data))

	packet_reader := create_reader(convert_byte_slice_to_word_slice(packet_data))

	packet, packet_ok := deserialize_packet(&packet_reader, recv_stream.temp_allocator)
	assert(packet.header.data_length > 0)

	// TODO(Thomas): MTU or MAX_FRAGMENT_SIZE here?
	assert(packet.header.data_length <= MTU)

	defer recv_stream_free_temp_allocator(recv_stream)
	assert(packet_ok)
	if !packet_ok {
		return false
	}

	qos := QOS(packet.header.qos)

	switch qos {
	case .Best_Effort:
		// TODO(Thomas): Think about wether we should just have everything be fragment
		// and that way not having to special case anything

		// Process fragment
		fragment_ok := process_fragment(
			packet.header.sequence,
			packet.header.packet_type,
			packet.data[:packet.header.data_length],
			recv_stream,
		)
		assert(fragment_ok)
		if !fragment_ok {
			return false
		}
	case .Reliable:
	}

	return true
}

process_fragment :: proc(
	sequence: u16,
	packet_type: u32,
	fragment_data: []u8,
	recv_stream: ^Recv_Stream,
) -> bool {
	assert(len(fragment_data) > 0)
	assert(len(fragment_data) <= MAX_FRAGMENT_SIZE + size_of(Fragment_Header))


	fragment_reader := create_reader(convert_byte_slice_to_word_slice(fragment_data))
	fragment, fragment_ok := deserialize_fragment(&fragment_reader, recv_stream.temp_allocator)
	assert(fragment_ok)
	if !fragment_ok {
		return false
	}

	log.info("len(fragment.data): ", len(fragment.data))
	assert(len(fragment.data) > 0)
	assert(len(fragment.data) <= MAX_FRAGMENT_SIZE)

	index := get_sequence_index(sequence)

	if recv_stream.realtime_packet_buffer.entries[index].sequence == ENTRY_SENTINEL_VALUE {
		recv_stream.realtime_packet_buffer.entries[index] = Realtime_Packet_Entry {
			packet_type = packet_type,
			sequence = u32(sequence),
			entry = Fragment_Entry {
				num_fragments = fragment.header.num_fragments,
				received_fragments = 1,
			},
		}

		mem.copy(
			&recv_stream.realtime_packet_buffer.entries[index].entry.fragments[fragment.header.fragment_id].data[0],
			&fragment.data[0],
			len(fragment.data),
		)

		recv_stream.realtime_packet_buffer.entries[index].entry.fragments[fragment.header.fragment_id].data_length =
			len(fragment.data)

		recv_stream.realtime_packet_buffer.entries[index].sequence = u32(sequence)

		// TODO(Thomas): Is this correct?? We'll need more sophisticated handling of this
		sequence := u32(sequence)
		if sequence > recv_stream.realtime_packet_buffer.current_sequence {
			recv_stream.realtime_packet_buffer.current_sequence = sequence
		}

	} else {
		recv_stream.realtime_packet_buffer.entries[index].entry.received_fragments += 1

		mem.copy(
			&recv_stream.realtime_packet_buffer.entries[index].entry.fragments[fragment.header.fragment_id].data[0],
			&fragment.data[0],
			len(fragment_data),
		)

		recv_stream.realtime_packet_buffer.entries[index].entry.fragments[fragment.header.fragment_id].data_length =
			len(fragment.data)

	}

	return true
}

@(require_results)
get_sequence_index :: proc(sequence: u16) -> i32 {
	return i32(sequence % MAX_ENTRIES)
}
