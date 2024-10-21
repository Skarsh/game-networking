package protocol

import "base:runtime"
import queue "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:net"
import "core:testing"

MAX_FRAGMENTS_PER_PACKET :: 256
MAX_FRAGMENT_SIZE :: 1024
MAX_PACKET_SIZE :: MAX_FRAGMENTS_PER_PACKET * MAX_FRAGMENT_SIZE

// Used to represent empty entries since it cannot occur
// by 16 bit sequence numbers.
ENTRY_SENTINEL_VALUE :: 0xFFFF_FFFF

MAX_ENTRIES :: 256

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

	socket, socket_ok := create_udp_socket(address, port)
	assert(socket_ok)

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

	switch qos {
	case .Best_Effort:
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

			flush_ok := flush_bits(&fragment_writer)
			assert(flush_ok)

			packet_bytes := create_net_packet(
				send_stream.allocator,
				send_stream.current_sequence,
				qos,
				packet_type,
				convert_word_slice_to_byte_slice(fragment_writer.buffer),
			)

			log.info("len of packet_bytes pushed onto queue: ", len(packet_bytes))
			push_ok, push_err := queue.push_back(&send_stream.queue, packet_bytes)
			assert(push_ok)
			assert(push_err == nil)
		}

	case .Reliable:
	}

	log.info("send_stream.current_sequence: ", send_stream.current_sequence)
	send_stream.current_sequence += 1
}

process_send_stream :: proc(send_stream: ^Send_Stream) {
	log.info("process_send_stream")
	for packet_bytes in queue.pop_front_safe(&send_stream.queue) {

		log.info("len(packet_bytes): ", len(packet_bytes))
		bytes_written, err := net.send_udp(send_stream.socket, packet_bytes, send_stream.endpoint)

		if err != nil {
			log.error("Error when calling 'net.send_udp': ", err)
		}
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
	for i in 0 ..< len(realtime_packet_buffer.entries) do realtime_packet_buffer.entries[i].sequence = ENTRY_SENTINEL_VALUE

	socket, socket_ok := create_udp_socket(address, port)
	assert(socket_ok)

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

// TODO(Thomas): Proper error handling, also something else needs
// to call this continously
recv_packet :: proc(recv_stream: ^Recv_Stream) -> bool {
	bytes_read, remote_endpoint, recv_err := net.recv_udp(
		recv_stream.socket,
		recv_stream.net_packet_buf[:],
	)

	if (recv_err != nil) {
		return false
	}

	// TODO(Thomas): Return false or some error type here?
	if bytes_read == 0 {
		return false
	}

	ok := process_packet(recv_stream.net_packet_buf[:bytes_read], recv_stream)
	assert(ok)
	if (!ok) {
		return false
	}

	return true
}

process_packet :: proc(packet_data: []u8, recv_stream: ^Recv_Stream) -> bool {
	assert(len(packet_data) > 0)
	assert(len(packet_data) <= MTU)

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

advance_packet_buffer_sequence :: proc(
	sequence: u16,
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
) {
	assert(realtime_packet_buffer.current_sequence <= u32(math.max(u16)))
	if !sequence_greater_than(sequence, u16(realtime_packet_buffer.current_sequence)) {
		return
	}

	oldest_sequence: u16 = sequence - MAX_ENTRIES + 1

	for i in 0 ..< MAX_ENTRIES {
		exists := realtime_packet_buffer.entries[i].sequence != ENTRY_SENTINEL_VALUE
		if exists {
			if sequence_less_than(
				u16(realtime_packet_buffer.entries[i].sequence),
				oldest_sequence,
			) {
				log.info("Remove old packet entry: ", realtime_packet_buffer.entries[i].sequence)
				realtime_packet_buffer.entries[i].sequence = ENTRY_SENTINEL_VALUE
			}
		}
	}

	realtime_packet_buffer.current_sequence = u32(sequence)
}

process_fragment :: proc(
	packet_sequence: u16,
	packet_type: u32,
	fragment_data: []u8,
	recv_stream: ^Recv_Stream,
) -> bool {

	assert(len(fragment_data) > 0)
	if len(fragment_data) <= 0 {
		log.error("len(fragment_data) <= 0 - ", len(fragment_data))
		return false
	}

	assert(len(fragment_data) <= MAX_FRAGMENT_SIZE + size_of(Fragment_Header))
	if len(fragment_data) > MAX_FRAGMENT_SIZE + size_of(Fragment_Header) {
		log.error(
			"len(fragment_data) > MAX_FRAGMENT_SIZE + size_of(Fragment_Header) - ",
			len(fragment_data),
		)
		return false
	}

	fragment_reader := create_reader(convert_byte_slice_to_word_slice(fragment_data))
	fragment, fragment_ok := deserialize_fragment(&fragment_reader, recv_stream.temp_allocator)
	assert(fragment_ok)
	if !fragment_ok {
		log.error("Deserializing fragment failed")
		return false
	}

	assert(len(fragment.data) > 0)
	if len(fragment.data) <= 0 {
		log.error("len(fragment.data) <= 0 - ", len(fragment.data))
		return false
	}

	assert(len(fragment.data) <= MAX_FRAGMENT_SIZE)
	if len(fragment.data) > MAX_FRAGMENT_SIZE {
		log.error("len(fragment.data) >= max_fragment_size - ", len(fragment.data))
		return false
	}

	num_fragments := int(fragment.header.num_fragments)


	assert(num_fragments > 0 && num_fragments <= MAX_FRAGMENTS_PER_PACKET)
	if num_fragments <= 0 || num_fragments > MAX_FRAGMENTS_PER_PACKET {
		log.error("num fragments is outside of range: ", num_fragments)
		return false
	}

	fragment_id := int(fragment.header.fragment_id)


	assert(fragment_id >= 0 && fragment_id <= num_fragments)
	if fragment_id < 0 || fragment_id >= num_fragments {
		log.error("fragment_id is outside of range: ", fragment_id)
		return false
	}


	if fragment_id != num_fragments - 1 && len(fragment.data) != MAX_FRAGMENT_SIZE {
		log.error("Non-last fragment has size not equal to MAX_FRAGMENT_SIZE")
		return false
	}

	if sequence_difference(
		   packet_sequence,
		   u16(recv_stream.realtime_packet_buffer.current_sequence),
	   ) >
	   1024 {
		log.errorf(
			"Packet sequence number is wildly out of range - packet_sequence: %v, packet_buffer.current_sequence: ",
			packet_sequence,
			recv_stream.realtime_packet_buffer.current_sequence,
		)
		return false
	}

	index := get_sequence_index(packet_sequence)

	entry := &recv_stream.realtime_packet_buffer.entries[index]

	exists := entry.sequence != ENTRY_SENTINEL_VALUE

	if exists && entry.sequence != u32(packet_sequence) {
		log.errorf(
			"Entry exists but has different sequence number than the fragment - entry.sequence: %d, packet_sequence: %d",
			entry.sequence,
			packet_sequence,
		)
		return false
	}

	// TODO(Thomas): Make an array to hold the exists value for each entry instead?
	if !exists {

		advance_packet_buffer_sequence(packet_sequence, recv_stream.realtime_packet_buffer)

		entry^ = Realtime_Packet_Entry {
			packet_type = packet_type,
			sequence = u32(packet_sequence),
			entry = Fragment_Entry {
				num_fragments = fragment.header.num_fragments,
				received_fragments = 1,
			},
		}
	}

	exists = entry.sequence != ENTRY_SENTINEL_VALUE

	assert(exists)
	assert(entry.sequence == u32(packet_sequence))

	if num_fragments != int(entry.entry.num_fragments) {
		log.errorf(
			"Total number of fragments is different for packet than for the entry - packet: %d, entry: %d",
			num_fragments,
			entry.entry.num_fragments,
		)
		return false
	}

	assert(fragment_id < num_fragments)
	assert(fragment_id < MAX_FRAGMENTS_PER_PACKET)
	assert(num_fragments <= MAX_FRAGMENTS_PER_PACKET)

	fragment_data := &entry.entry.fragments[fragment.header.fragment_id]
	fragment_data.data_length = len(fragment.data)

	mem.copy(&fragment_data.data[0], &fragment.data[0], len(fragment.data))

	entry.entry.received_fragments += 1

	return true
}

process_recv_stream :: proc(
	recv_stream: ^Recv_Stream,
	allocator: runtime.Allocator,
) -> (
	u32,
	[]u8,
	bool,
) {
	// Process the packet buffer, assemble the fragments into complete 
	// packets if they are completed, delete fragments that have older
	// sequence number than the freshest one, etc...

	// NOTE(Thomas): Prune any packets with older sequence number than what we have
	// by keeping track of them in a valid list?

	// Assemble packet bytes for the packet that is 
	packet_type, packet_data, packet_data_ok := assemble_fragments(
		recv_stream.realtime_packet_buffer,
		allocator,
	)
	assert(packet_data_ok)

	return packet_type, packet_data, true
}

assemble_fragments :: proc(
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
	allocator: runtime.Allocator,
) -> (
	u32,
	[]u8,
	bool,
) {
	log.info("current_sequence: ", realtime_packet_buffer.current_sequence)
	index := get_sequence_index(u16(realtime_packet_buffer.current_sequence))
	log.info("index: ", index)

	packet_type := realtime_packet_buffer.entries[index].packet_type
	entry := &realtime_packet_buffer.entries[index].entry
	num_fragments: u32 = u32(entry.num_fragments)
	total_size := 0

	// Calculate total size
	for fragment in entry.fragments[:num_fragments] {
		total_size += fragment.data_length
	}

	log.info("total_size: ", total_size)

	// Allocate and copy data
	packet_data := make([]u8, total_size, allocator)
	offset := 0
	for &fragment in entry.fragments[:num_fragments] {
		log.info("fragment.data_length: ", fragment.data_length)
		mem.copy(&packet_data[offset], &fragment.data[0], fragment.data_length)
		offset += fragment.data_length
	}

	log.info("packet_type: ", packet_type)
	log.info("len(packet_data): ", len(packet_data))
	return packet_type, packet_data, true
}

// ------------- Utility procedures -------------

@(require_results)
get_sequence_index :: proc(sequence: u16) -> i32 {
	return i32(sequence % MAX_ENTRIES)
}

create_udp_socket :: proc(address: string, port: int) -> (net.UDP_Socket, bool) {
	addr := net.parse_address(address)
	socket, err := net.make_bound_udp_socket(addr, port)
	return socket, err == nil
}

// ------------- Tests -------------

@(test)
test_create_udp_socket :: proc(t: ^testing.T) {
	socket, ok := create_udp_socket("127.0.0.1", 8080)
	testing.expect(t, ok, "Failed to create UDP socket")
	defer net.close(socket)
}

@(test)
test_enqueue_packet :: proc(t: ^testing.T) {
	allocator := context.allocator
	send_stream := create_send_stream(allocator, "127.0.0.1", 8080, "127.0.0.1", 8081)
	defer free_send_stream(&send_stream)

	packet_data := []u8{1, 2, 3, 4, 5}
	enqueue_packet(&send_stream, .Best_Effort, 1, packet_data)

	testing.expect(t, send_stream.current_sequence == 1, "Sequence should be incremented")
	testing.expect(t, len(send_stream.queue.data) > 0, "Queue should not be empty")
}
