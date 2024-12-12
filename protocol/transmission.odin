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

// TODO(Thomas): Find a better name for this
// The packet data type returned back to the caller / user
Packet_Data :: struct {
	type: u32,
	data: []u8,
}

Send_Stream :: struct {
	allocator:        runtime.Allocator,
	queue:            queue.Queue([]u8),
	socket:           Socket,
	endpoint:         net.Endpoint,
	current_sequence: u16,
}

create_send_stream :: proc(
	allocator: runtime.Allocator,
	socket: Socket,
	endpoint_address: string,
	endpoint_port: int,
) -> Send_Stream {
	packet_queue := queue.Queue([]u8){}
	alloc_err := queue.init(&packet_queue, MAX_OUTGOING_PACKETS, allocator)
	assert(alloc_err == .None)
	if alloc_err != .None {
		log.error("alloc error when init queue: ", alloc_err)
	}

	endpoint_string := fmt.tprintf("%s:%d", endpoint_address, endpoint_port)

	endpoint, endpoint_ok := net.parse_endpoint(endpoint_string)
	assert(endpoint_ok)
	if !endpoint_ok {
		log.error("failed to parse endpoint")
	}

	return Send_Stream {
		allocator = allocator,
		queue = packet_queue,
		socket = socket,
		endpoint = endpoint,
		current_sequence = 0,
	}
}

free_send_stream :: proc(send_stream: ^Send_Stream) {
	err := free_all(send_stream.allocator)
	assert(err == nil)
	if err != nil {
		log.error("failed to free_all")
	}

	// NOTE(Thomas): Initing the queue here again is necessary for the queue to be valid.
	// TODO(Thomas): Is there a better way to do this? 
	alloc_err := queue.init(&send_stream.queue, MAX_OUTGOING_PACKETS, send_stream.allocator)
	assert(alloc_err == .None)
}

destroy_send_stream :: proc(send_stream: ^Send_Stream) {
	free_send_stream(send_stream)
	socket_close(send_stream.socket)
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
	if data_size <= 0 {
		log.error("data_size <= 0")
	}

	assert(data_size <= MTU)
	if data_size > MTU {
		log.error("data_size > MTU")
	}

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
	if !serialize_packet_ok {
		log.error("failed to serialize packet form header and byte slice")
	}

	flush_ok := flush_bits(&packet_writer)
	assert(flush_ok)
	if !flush_ok {
		log.error("failed to flush")
	}

	return convert_word_slice_to_byte_slice(packet_writer.buffer)
}

// TODO(Thomas): Make sure the sequence number wraps around
enqueue_packet :: proc(send_stream: ^Send_Stream, qos: QOS, packet_type: u32, packet_data: []u8) {
	log.infof(
		"enqueing packet with qos: %v, type: %d and len(packet_data): %d",
		qos,
		packet_type,
		len(packet_data),
	)
	assert(len(packet_data) > 0)
	if len(packet_data) <= 0 {
		log.error("len(packet_data) <= 0")
	}

	assert(len(packet_data) <= MAX_PACKET_SIZE)
	if len(packet_data) > MAX_PACKET_SIZE {
		log.error("len(pacet_data) > MAX_PACKET_SIZE")
	}

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
			if !serialize_fragment_ok {
				log.error("failed to serialize fragment")
			}

			flush_ok := flush_bits(&fragment_writer)
			assert(flush_ok)
			if !flush_ok {
				log.error("failed to flush")
			}

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
			if !push_ok {
				log.error("failed to push onto queue: len(packet_bytes)", len(packet_bytes))
			}
			assert(push_err == nil)
			if push_err != nil {
				log.error("error when pushing onto queue: ", push_err)
			}
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

		bytes_written, err := send_socket_packet(
			send_stream.socket,
			packet_bytes,
			send_stream.endpoint,
		)

		switch socket_err in err {
		case net.Network_Error:
			assert(socket_err == nil)
			if socket_err != nil {
				log.error("Error when calling 'net.send_udp': ", socket_err)
			}
		case Interception_Socket_Error:
			// TODO(Thomas): What to do here?
			log.error("")
		}
	}

	free_send_stream(send_stream)
}

Fragment_Data :: struct {
	data_length: int,
	data:        [MAX_FRAGMENT_SIZE]u8,
}

Fragment_Entry :: struct {
	num_fragments:      u32,
	received_fragments: u32,
	// TODO(Thomas): Does this belong in the Realtime_Packet_Entry instead?
	completed:          bool,
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
	socket:                 Socket,
	net_packet_buf:         [MTU]u8,
}

recv_stream_free_temp_allocator :: proc(recv_stream: ^Recv_Stream) {
	free_all(recv_stream.temp_allocator)
}

create_recv_stream :: proc(
	persistent_allocator: runtime.Allocator,
	temp_allocator: runtime.Allocator,
	socket: Socket,
) -> Recv_Stream {
	realtime_packet_buffer := new(Realtime_Packet_Buffer, persistent_allocator)
	for i in 0 ..< len(realtime_packet_buffer.entries) do realtime_packet_buffer.entries[i].sequence = ENTRY_SENTINEL_VALUE

	err := set_socket_blocking(socket, false)
	switch blocking_err in err {
	case net.Network_Error:
		if blocking_err != nil {
			log.error("udp socket set blocking error: ", blocking_err)
		}
		assert(blocking_err == nil)

	case Interception_Socket_Error:
	}

	return Recv_Stream {
		persistent_allocator = persistent_allocator,
		temp_allocator = temp_allocator,
		realtime_packet_buffer = realtime_packet_buffer,
		socket = socket,
	}
}

destroy_recv_stream :: proc(recv_stream: ^Recv_Stream) {
	free(recv_stream.realtime_packet_buffer, recv_stream.persistent_allocator)
	socket_close(recv_stream.socket)
}

// TODO(Thomas): Proper error handling, also something else needs
// to call this continously
recv_packet :: proc(recv_stream: ^Recv_Stream) -> bool {
	bytes_read, remote_endpoint, err := recv_socket_packet(
		recv_stream.socket,
		recv_stream.net_packet_buf[:],
	)

	log.infof("recv packet --- bytes_read: %d, remote_endpoint: %v", bytes_read, remote_endpoint)

	switch recv_err in err {
	case net.Network_Error:
		// TODO(Thomas): I'd prefer to somehow not have to do the check for OS like this.
		// TOOD(Thomas): Why is this different between Windows and Linux really?
		when ODIN_OS == .Windows {
			if recv_err != nil && recv_err != net.UDP_Recv_Error.Would_Block {
				log.error("recv error: ", recv_err)
				return false
			}
		} else when ODIN_OS == .Linux {
			if recv_err != nil && recv_err != net.UDP_Recv_Error.Timeout {
				log.error("recv error: ", recv_err)
				return false
			}
		} else {
			// Handle other operating systems or provide a default behavior
			if recv_err != nil {
				log.error("recv error: ", recv_err)
				return false
			}
		}

	case Interception_Socket_Error:
		// TODO(Thomas): What to do here?
		log.error("")
	}

	// TODO(Thomas): Return false or some error type here?
	if bytes_read == 0 {
		return false
	}


	ok := process_packet(recv_stream.net_packet_buf[:bytes_read], recv_stream)
	assert(ok)
	if (!ok) {
		log.error("failed to process packet")
		return false
	}

	return true
}

process_packet :: proc(packet_data: []u8, recv_stream: ^Recv_Stream) -> bool {
	log.info("processing packet_data, len(packet_data): ", len(packet_data))
	assert(len(packet_data) > 0)
	if len(packet_data) <= 0 {
		log.error("len(packet_data) <= 0")
	}

	assert(len(packet_data) <= MTU)
	if len(packet_data) > MTU {
		log.error("len(packet_data) > MTU")
	}

	packet_reader := create_reader(convert_byte_slice_to_word_slice(packet_data))

	packet, packet_ok := deserialize_packet(&packet_reader, recv_stream.temp_allocator)
	assert(packet_ok)
	if !packet_ok {
		log.error("failed to deserialize packet")
		return false
	}

	assert(packet.header.data_length > 0)
	if packet.header.data_length <= 0 {
		log.error("packet.header.data_length <= 0")
	}

	// TODO(Thomas): MTU or MAX_FRAGMENT_SIZE here?
	assert(packet.header.data_length <= MTU)
	if packet.header.data_length > MTU {
		log.error("packet.header.data_length > MTU")
	}

	defer recv_stream_free_temp_allocator(recv_stream)

	qos := QOS(packet.header.qos)

	switch qos {
	case .Best_Effort:
		fragment_ok := process_fragment(
			packet.header.sequence,
			packet.header.packet_type,
			packet.data[:packet.header.data_length],
			recv_stream,
		)
		assert(fragment_ok)
		if !fragment_ok {
			log.error("failed to process fragment")
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
			}

			realtime_packet_buffer.entries[i].sequence = ENTRY_SENTINEL_VALUE
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
			"Packet sequence number is wildly out of range - packet_sequence: %d, packet_buffer.current_sequence: %d",
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
				num_fragments = u32(fragment.header.num_fragments),
				completed = false,
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

// TODO(Thomas): This needs to assemble the fragments for packets that are done.
// Now it only does it for the current sequence, which only is kinda correct if there's
// never a dropped or out-of-order packet, which obviously won't work for us.
// This procedure takes in an allocator, which it uses to allocate the total size
// needed for the packet data. It is the calller's responsibility to free this memory. This is also
process_realtime_packet_buffer :: proc(
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
	allocator: runtime.Allocator,
) -> (
	Packet_Data,
	bool,
) {
	// TODO(Thomas): This will only assemble and return the first packet that has received
	// all the fragments and has not been completed before. 
	for idx in 0 ..< len(realtime_packet_buffer.entries) {
		fragment_entry := &realtime_packet_buffer.entries[idx].entry
		if fragment_entry.num_fragments == fragment_entry.received_fragments &&
		   !fragment_entry.completed {

			index := get_sequence_index(u16(realtime_packet_buffer.entries[idx].sequence))

			packet_data, packet_data_ok := assemble_fragments(
				realtime_packet_buffer.entries[idx].packet_type,
				&realtime_packet_buffer.entries[idx].entry,
				allocator,
			)
			if !packet_data_ok {
				log.error("Failed to assemble fragments")
				return Packet_Data{}, false
			}

			return packet_data, true
		}
	}

	return Packet_Data{}, true
}

// This procedure takes in an allocator, which it uses to allocate the total size
// needed for the packet data. It is the calller's responsibility to free this memory. This is also
// why the structure allocated with the data is returned even if it the fails data length checks
assemble_fragments :: proc(
	packet_type: u32,
	fragment_entry: ^Fragment_Entry,
	allocator: runtime.Allocator,
) -> (
	Packet_Data,
	bool,
) {
	if fragment_entry.num_fragments != fragment_entry.received_fragments {
		log.errorf(
			"fragment entry's num_fragments is != to received_fragments, %d, %d",
			fragment_entry.num_fragments,
			fragment_entry.received_fragments,
		)
		return Packet_Data{}, false
	}

	num_fragments: u32 = u32(fragment_entry.num_fragments)
	total_size := 0

	// Calculate total size
	for fragment in fragment_entry.fragments[:num_fragments] {
		total_size += fragment.data_length
	}

	// Allocate and copy data
	data, alloc_err := make([]u8, total_size, allocator)
	assert(alloc_err == .None)
	if alloc_err != .None {
		log.error("alloc error: ", alloc_err)
	}

	packet_data := Packet_Data {
		type = packet_type,
		data = data,
	}

	offset := 0

	for &fragment in fragment_entry.fragments[:num_fragments] {
		if fragment.data_length <= 0 {
			log.error("fragment data length is <= 0, ", fragment.data_length)
			return packet_data, false
		}

		if fragment.data_length > MAX_FRAGMENT_SIZE {
			log.error("fragment data length is >= MAX_FRAGMENT_SIZE, ", fragment.data_length)
			return packet_data, false
		}

		mem.copy(&packet_data.data[offset], &fragment.data[0], fragment.data_length)
		offset += fragment.data_length
	}


	fragment_entry.completed = true
	return packet_data, true
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

// TODO(Thomas): Add more test cases
@(test)
test_enqueue_packet :: proc(t: ^testing.T) {
	allocator := context.allocator
	socket, socket_ok := create_socket(.UDP, "127.0.0.1", 8080)
	testing.expect(t, socket_ok, "Creating socket should be ok")
	send_stream := create_send_stream(allocator, socket, "127.0.0.1", 8081)
	defer free_send_stream(&send_stream)

	packet_data := []u8{1, 2, 3, 4, 5}
	enqueue_packet(&send_stream, .Best_Effort, 1, packet_data)

	testing.expect(t, send_stream.current_sequence == 1, "Sequence should be incremented")
	testing.expect(t, len(send_stream.queue.data) > 0, "Queue should not be empty")
}

@(test)
test_assemble_fragments :: proc(t: ^testing.T) {
	logger := Test_Redirect_Logger{}
	defer destroy_test_redirect_logger(&logger)
	prev_logger := context.logger
	context.logger = log.Logger {
		data      = &logger,
		procedure = test_redirect_log_handler,
	}
	defer context.logger = prev_logger

	// Test case 1: Basic assembly with two fragments
	{
		packet_type: u32 = 2
		fragment1_data := [MAX_FRAGMENT_SIZE]u8{}
		fragment1_data[0] = 1
		fragment1_data[1] = 2
		fragment1_data[2] = 3

		fragment2_data := [MAX_FRAGMENT_SIZE]u8{}
		fragment2_data[0] = 4
		fragment2_data[1] = 5
		fragment2_data[2] = 6

		fragment_entry := new(Fragment_Entry)
		defer free(fragment_entry)
		fragment_entry.num_fragments = 2
		fragment_entry.received_fragments = 2

		fragment_entry.fragments[0] = Fragment_Data {
			data_length = 3,
			data        = fragment1_data,
		}

		fragment_entry.fragments[1] = Fragment_Data {
			data_length = 3,
			data        = fragment2_data,
		}

		assembled_packet_data, assembled_packet_data_ok := assemble_fragments(
			packet_type,
			fragment_entry,
			context.allocator,
		)
		defer delete(assembled_packet_data.data)

		testing.expectf(t, assembled_packet_data_ok, "assembling fragments should succeed")
		testing.expect_value(t, assembled_packet_data.type, packet_type)
		testing.expect_value(t, assembled_packet_data.data[0], 1)
		testing.expect_value(t, assembled_packet_data.data[1], 2)
		testing.expect_value(t, assembled_packet_data.data[2], 3)
		testing.expect_value(t, assembled_packet_data.data[3], 4)
		testing.expect_value(t, assembled_packet_data.data[4], 5)
		testing.expect_value(t, assembled_packet_data.data[5], 6)
	}

	// Test case 2: Max number of fragments
	{
		packet_type: u32 = 2
		fragment_entry := new(Fragment_Entry)
		defer free(fragment_entry)
		for i in 0 ..< MAX_FRAGMENTS_PER_PACKET {
			fragment_data := [MAX_FRAGMENT_SIZE]u8{}
			for &b in fragment_data {
				b = u8(i % 255)
			}
			fragment_entry.fragments[i] = Fragment_Data {
				data_length = len(fragment_data),
				data        = fragment_data,
			}
		}
		fragment_entry.num_fragments = MAX_FRAGMENTS_PER_PACKET
		fragment_entry.received_fragments = MAX_FRAGMENTS_PER_PACKET

		assembled_packet_data, assembled_packet_data_ok := assemble_fragments(
			packet_type,
			fragment_entry,
			context.allocator,
		)
		defer delete(assembled_packet_data.data)
		testing.expectf(t, assembled_packet_data_ok, "assembling fragments should succeed")
		testing.expect_value(t, assembled_packet_data.type, packet_type)

		for i in 0 ..< MAX_FRAGMENTS_PER_PACKET {
			fragment_data := assembled_packet_data.data[i *
			MAX_FRAGMENT_SIZE:(i + 1) *
			MAX_FRAGMENT_SIZE]

			for b in fragment_data {
				testing.expect_value(t, b, u8(i % 255))
			}
		}
	}

	// Test case 3: Missing fragment, should return false
	{
		packet_type: u32 = 2
		fragment_data := [MAX_FRAGMENT_SIZE]u8{}
		fragment_data[0] = 1
		fragment_data[1] = 2
		fragment_data[2] = 3

		fragment_entry := new(Fragment_Entry, context.allocator)
		defer free(fragment_entry)
		fragment_entry.num_fragments = 2
		fragment_entry.received_fragments = 1

		fragment_entry.fragments[0] = Fragment_Data {
			data_length = 3,
			data        = fragment_data,
		}

		assembled_packet_data, assembled_packet_data_ok := assemble_fragments(
			packet_type,
			fragment_entry,
			context.allocator,
		)
		defer delete(assembled_packet_data.data)

		testing.expectf(t, !assembled_packet_data_ok, "assembling fragments should succeed")
		testing.expect_value(t, assembled_packet_data.type, packet_type)
	}
}

@(test)
test_process_realtime_packet_buffer :: proc(t: ^testing.T) {

	// Test case 1: Simple packet with all fragments received are being assembled.
	{
		realtime_packet_buffer := new(Realtime_Packet_Buffer, context.allocator)
		defer free(realtime_packet_buffer)

		packet_type: u32 = 1
		fragment_data := [MAX_FRAGMENT_SIZE]u8{}
		fragment_data[0] = 1
		fragment_data[1] = 2
		fragment_data[2] = 3

		fragment_entry := new(Fragment_Entry, context.allocator)
		defer free(fragment_entry)

		fragment_entry.num_fragments = 1
		fragment_entry.received_fragments = 1
		fragment_entry.fragments[0] = Fragment_Data {
			data_length = 3,
			data        = fragment_data,
		}

		realtime_packet_buffer.entries[0].entry = fragment_entry^

		packet_data, packet_data_ok := process_realtime_packet_buffer(
			realtime_packet_buffer,
			context.allocator,
		)
		testing.expectf(t, packet_data_ok, "processing realtime packet buffer should succeed")
		defer delete(packet_data.data)

		testing.expect_value(t, packet_data.data[0], 1)
		testing.expect_value(t, packet_data.data[1], 2)
		testing.expect_value(t, packet_data.data[2], 3)
	}

	// Test case 2: If fragment is missing, packet is not assembled, should not crash.
	{

	}

	// Test case 3: If more than one packet has gotten all their fragments received, they should
	//              all be completed.

}
