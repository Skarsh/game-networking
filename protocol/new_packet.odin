package protocol

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:testing"

MAX_FRAGMENTS_PER_PACKET :: 256
MAX_FRAGMENT_SIZE :: 1024
MAX_PACKET_SIZE :: MAX_FRAGMENTS_PER_PACKET * MAX_FRAGMENT_SIZE

MAX_ENTRIES :: 256

// Used to represent empty entries since it cannot occur
// by 16 bit sequence numbers.
ENTRY_SENTINEL_VALUE :: 0xFFFF_FFFF

Test_Packet_A :: struct {
	a: i32,
	b: i32,
	c: i32,
}

// This will be larger than MTU, so needs to be split into fragments
Test_Packet_B :: struct {
	items: [2048]i32,
}

Test_Packet_C :: struct {
	velocity: Vector3,
	position: Vector3,
}

Packet_Type :: enum {
	Test_A,
	Test_B,
	Test_C,
	Chunk,
}

Packet_Header :: struct {
	crc32:       u32,
	packet_type: u32,
	data_length: u32,
	sequence:    u16,
	is_fragment: bool,
}

Packet :: struct {
	packet_header: Packet_Header,
	data:          []u8,
}

// TODO(Thomas): Make the fragment_size u16 instead
Fragment_Header :: struct {
	fragment_size: u32,
	fragment_id:   u8,
	num_fragments: u8,
}

Fragment :: struct {
	fragment_header: Fragment_Header,
	data:            []u8,
}

Fragment_Entry :: struct {
	num_fragments:      u8,
	received_fragments: u8,
	fragments:          [][]u8,
}

Complete_Entry :: struct {
	data: []u8,
}

Packet_Entry :: struct {
	packet_type: Packet_Type,
	sequence:    u32,
	entry:       union {
		Complete_Entry,
		Fragment_Entry,
	},
}


Packet_Buffer :: struct {
	current_sequence: u32,
	entries:          [MAX_ENTRIES]Packet_Entry,
}


init_packet_buffer :: proc(packet_buffer: ^Packet_Buffer) {
	for &entry in packet_buffer.entries {
		entry.sequence = ENTRY_SENTINEL_VALUE
	}
}

// ------------- Serializiation procedures -------------

@(require_results)
serialize_packet_header :: proc(bit_writer: ^Bit_Writer, packet_header: Packet_Header) -> bool {

	serialize_u32(bit_writer, packet_header.crc32) or_return

	// NOTE(Thomas): This len(Packet_Type) - 1 trick only works if 
	// there is more than one variant in the Packet_Type enum
	write_bits(bit_writer, u32(packet_header.packet_type), len(Packet_Type) - 1) or_return

	serialize_u32(bit_writer, packet_header.data_length) or_return
	serialize_u16(bit_writer, packet_header.sequence) or_return
	serialize_bool(bit_writer, packet_header.is_fragment) or_return

	return true
}

@(require_results)
serialize_packet_from_header_and_byte_slice :: proc(
	bit_writer: ^Bit_Writer,
	packet_header: Packet_Header,
	data: []u8,
) -> bool {

	serialize_packet_header(bit_writer, packet_header) or_return

	// Ensure we're aligned with next byte boundary
	write_align(bit_writer) or_return

	write_bytes(bit_writer, data) or_return

	return true
}

@(require_results)
serialize_packet :: proc(bit_writer: ^Bit_Writer, packet: Packet) -> bool {

	serialize_packet_header(bit_writer, packet.packet_header) or_return

	// Ensure we're aligned with next byte boundary
	write_align(bit_writer) or_return

	write_bytes(bit_writer, packet.data) or_return

	return true
}

@(require_results)
serialize_fragment_header :: proc(
	bit_writer: ^Bit_Writer,
	fragment_header: Fragment_Header,
) -> bool {
	serialize_u32(bit_writer, fragment_header.fragment_size) or_return
	serialize_u8(bit_writer, fragment_header.fragment_id) or_return
	serialize_u8(bit_writer, fragment_header.num_fragments) or_return

	return true
}

@(require_results)
serialize_fragment :: proc(bit_writer: ^Bit_Writer, fragment: Fragment) -> bool {

	serialize_fragment_header(bit_writer, fragment.fragment_header) or_return

	// Ensure we're aligned with next byte boundary
	serialize_align(bit_writer) or_return

	serialize_bytes(bit_writer, fragment.data) or_return

	return true
}

@(require_results)
serialize_test_packet_b :: proc(bit_writer: ^Bit_Writer, test_packet: Test_Packet_B) -> bool {
	for item in test_packet.items {
		if !serialize_integer(bit_writer, item, math.min(i32), math.max(i32)) {
			return false
		}
	}

	return true
}

// ------------- Deserializiation procedures -------------

@(require_results)
deserialize_packet_header :: proc(bit_reader: ^Bit_Reader) -> (Packet_Header, bool) {

	crc32, crc32_ok := deserialize_u32(bit_reader)
	if !crc32_ok {
		return Packet_Header{}, false
	}

	packet_type, packet_type_ok := read_bits(bit_reader, len(Packet_Type) - 1)
	if !packet_type_ok {
		return Packet_Header{}, false
	}

	data_length, data_length_ok := deserialize_u32(bit_reader)
	if !data_length_ok {
		return Packet_Header{}, false
	}

	sequence, seq_ok := deserialize_u16(bit_reader)
	if !seq_ok {
		return Packet_Header{}, false
	}

	is_fragment, is_fragment_ok := deserialize_bool(bit_reader)
	if !is_fragment_ok {
		return Packet_Header{}, false
	}

	return Packet_Header {
			crc32 = crc32,
			packet_type = u32(packet_type),
			data_length = data_length,
			sequence = u16(sequence),
			is_fragment = is_fragment,
		},
		true
}

@(require_results)
deserialize_packet :: proc(
	bit_reader: ^Bit_Reader,
	allocator: runtime.Allocator,
) -> (
	Packet,
	bool,
) {
	packet_header, packet_header_ok := deserialize_packet_header(bit_reader)

	if !packet_header_ok {
		return Packet{}, false
	}

	if !read_align(bit_reader) {
		return Packet{}, false
	}

	data := make([]u8, packet_header.data_length, allocator)

	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		return Packet{}, false
	}

	return Packet{packet_header, data}, true
}

@(require_results)
deserialize_fragment_header :: proc(bit_reader: ^Bit_Reader) -> (Fragment_Header, bool) {

	fragment_size, fragment_size_ok := deserialize_u32(bit_reader)
	if !fragment_size_ok {
		return Fragment_Header{}, false
	}

	fragment_id, fragment_id_ok := deserialize_u8(bit_reader)
	if !fragment_id_ok {
		return Fragment_Header{}, false
	}

	num_fragments, num_fragments_ok := deserialize_u8(bit_reader)
	if !num_fragments_ok {
		return Fragment_Header{}, false
	}

	return Fragment_Header {
			fragment_size = fragment_size,
			fragment_id = fragment_id,
			num_fragments = num_fragments,
		},
		true
}

@(require_results)
deserialize_fragment :: proc(
	bit_reader: ^Bit_Reader,
	allocator: runtime.Allocator,
) -> (
	Fragment,
	bool,
) {

	fragment_header, fragment_header_ok := deserialize_fragment_header(bit_reader)
	if !fragment_header_ok {
		return Fragment{}, false
	}

	if !deserialize_align(bit_reader) {
		return Fragment{}, false
	}

	data := make([]u8, fragment_header.fragment_size, allocator)
	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		return Fragment{}, false
	}

	fragment := Fragment {
		fragment_header = fragment_header,
		data            = data,
	}

	return fragment, true
}

@(require_results)
deserialize_test_packet_b :: proc(bit_reader: ^Bit_Reader) -> (Test_Packet_B, bool) {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		item, ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
		if !ok {
			return Test_Packet_B{}, false
		}
		test_packet.items[i] = item
	}

	return test_packet, true
}

// ------------- Processing procedures -------------

receive_fragments :: proc(
	packet_buffer: ^Packet_Buffer,
	sequence: u32,
	allocator: runtime.Allocator,
) -> (
	Packet_Type,
	[]u8,
	bool,
) {
	// check if the sequence is valid and set
	if packet_buffer.entries[sequence].sequence != u32(sequence) {
		return Packet_Type.Test_A, nil, false
	}

	// get the entry
	fragment_entry := packet_buffer.entries[sequence].entry.(Fragment_Entry)

	// check if the amount of received fragments is equal to the amount of expected fragments
	if fragment_entry.received_fragments != fragment_entry.num_fragments {
		return Packet_Type.Test_A, nil, false
	}

	packet_type := packet_buffer.entries[sequence].packet_type

	// calculate the total packet size
	total_packet_size := 0
	for fragment in fragment_entry.fragments {
		total_packet_size += len(fragment)
	}

	assert(total_packet_size > 0)
	assert(total_packet_size <= MAX_PACKET_SIZE)

	// reassemble the packet, just the bytes though
	packet_data := make([]u8, total_packet_size, allocator)
	current_memory_offset := 0
	for idx in 0 ..< fragment_entry.num_fragments {
		fragment := fragment_entry.fragments[idx]
		fragment_size := len(fragment)
		mem.copy(&packet_data[current_memory_offset], &fragment[0], fragment_size)

		current_memory_offset += fragment_size
	}

	return packet_type, packet_data, true
}

process_fragment :: proc(
	packet_buffer: ^Packet_Buffer,
	sequence: u16,
	packet_type: Packet_Type,
	fragment: Fragment,
	allocator: runtime.Allocator,
) -> bool {
	assert(len(fragment.data) > 0)
	assert(len(fragment.data) <= MAX_FRAGMENT_SIZE)
	assert(fragment.fragment_header.fragment_size > 0)
	assert(fragment.fragment_header.fragment_size <= MAX_FRAGMENT_SIZE)

	index := get_sequence_index(sequence)

	// This is the first fragment we've gotten for this sequence number
	if packet_buffer.entries[index].sequence == ENTRY_SENTINEL_VALUE {

		// TODO(Thomas): Think more about this
		data: [][]u8 = make([][]u8, MAX_FRAGMENTS_PER_PACKET, allocator)

		data[fragment.fragment_header.fragment_id] = make(
			[]u8,
			fragment.fragment_header.fragment_size,
			allocator,
		)

		mem.copy(
			&data[fragment.fragment_header.fragment_id][0],
			&fragment.data[0],
			len(fragment.data),
		)

		packet_buffer.entries[index] = Packet_Entry {
			packet_type = packet_type,
			sequence = u32(sequence),
			entry = Fragment_Entry {
				num_fragments = fragment.fragment_header.num_fragments,
				received_fragments = 1,
				fragments = data,
			},
		}

		packet_buffer.entries[index].sequence = u32(sequence)
		packet_buffer.current_sequence = u32(sequence)
	} else {

		fragment_entry := &packet_buffer.entries[index].entry.(Fragment_Entry)
		assert(fragment_entry != nil)

		fragment_entry.fragments[fragment.fragment_header.fragment_id] = make(
			[]u8,
			fragment.fragment_header.fragment_size,
			allocator,
		)
		fragment_entry.received_fragments += 1

		mem.copy(
			&fragment_entry.fragments[fragment.fragment_header.fragment_id][0],
			&fragment.data[0],
			len(fragment.data),
		)

		packet_buffer.entries[index].sequence = u32(sequence)
		packet_buffer.current_sequence = u32(sequence)
	}

	return true
}

@(require_results)
process_packet :: proc(
	packet_buffer: ^Packet_Buffer,
	data: []u8,
	allocator: runtime.Allocator,
) -> bool {

	// TODO(Thomas): Remove assert in favour of returning false when confident
	assert(len(data) > 0)
	if (len(data) <= 0) {
		return false
	}

	// TODO(Thomas): Remove assert in favour of returning false when confident
	assert(len(data) <= MAX_PACKET_SIZE)
	if (len(data) > MAX_PACKET_SIZE) {
		return false
	}

	words := convert_byte_slice_to_word_slice(data)
	packet_reader := create_reader(words)

	packet, packet_ok := deserialize_packet(&packet_reader, allocator)
	if !packet_ok {
		return false
	}

	// TODO(Thomas): Deal with crc32 calculation properly and compare the 
	// Packet crc32 to the one we've calculated here
	protocol_id := PROTOCOL_ID
	protocol_id_bytes := transmute([4]u8)protocol_id
	crc32 := calculate_crc32(protocol_id_bytes[:])


	// For now, Chunk is the only packet type that is not deemed realtime(unreliable)
	#partial switch Packet_Type(packet.packet_header.packet_type) {
	case .Chunk:
	// Do chunk stuff

	case .Test_A:
	// This is a complete packet, and always will be
	case .Test_B:
		// This will be larger than MTU and hence fragmented
		if packet.packet_header.is_fragment {
			// NOTE(Thomas): Need to create new reader here, or reset since if not
			// the number of bits read will not match
			fragment_reader := create_reader(convert_byte_slice_to_word_slice(packet.data))

			fragment, fragment_ok := deserialize_fragment(&fragment_reader, allocator)
			if !fragment_ok {
				return false
			}

			// TODO(Thomas): Pass in the same allocator?
			process_fragment(
				packet_buffer,
				packet.packet_header.sequence,
				Packet_Type(packet.packet_header.packet_type),
				fragment,
				allocator,
			) or_return
		}
	case .Test_C:
	// This is a complete packet, and always will be
	}

	return true
}


split_packet_into_fragments :: proc(
	sequence: u16,
	packet_data: []u8,
	allocator: runtime.Allocator,
) -> []Fragment {

	num_fragments := 0

	packet_size := u32(len(packet_data))
	assert(packet_size > 0)
	assert(packet_size < MAX_PACKET_SIZE)

	remainder := packet_size % MAX_FRAGMENT_SIZE

	if remainder == 0 {
		num_fragments = int(packet_size) / MAX_FRAGMENT_SIZE
	} else {
		num_fragments = (int(packet_size) / MAX_FRAGMENT_SIZE) + 1
	}

	fragments := make([]Fragment, num_fragments, allocator)

	for &fragment, i in fragments {

		fragment_size := MAX_FRAGMENT_SIZE

		// The case where packet_size / MAX_FRAGMENT_SIZE does not divide evenly, we get a
		// remainder which will be the size of the last packet.
		if remainder != 0 && i == int(num_fragments) - 1 {
			fragment_size = int(remainder)
		}

		fragment.data = make([]u8, MAX_FRAGMENT_SIZE, allocator)

		mem.copy(&fragment.data[0], &packet_data[i * fragment_size], fragment_size)

		fragment.fragment_header.fragment_size = u32(fragment_size)
		fragment.fragment_header.fragment_id = u8(i)
		fragment.fragment_header.num_fragments = u8(num_fragments)
	}

	return fragments
}


// ------------- Utility procedures -------------


random_test_packet_b :: proc() -> Test_Packet_B {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		test_packet.items[i] = rand.int31()
	}
	return test_packet
}

@(require_results)
get_sequence_index :: proc(sequence: u16) -> i32 {
	return i32(sequence % MAX_ENTRIES)
}

@(require_results)
compare_packet :: proc(packet_a: Packet, packet_b: Packet) -> bool {
	equal_header := packet_a.packet_header == packet_b.packet_header
	equal_data := bytes.compare(packet_a.data, packet_b.data) == 0
	return equal_header && equal_data
}

@(require_results)
compare_fragment_header :: proc(
	fragment_header_a: Fragment_Header,
	fragment_header_b: Fragment_Header,
) -> bool {
	equal_fragment_size := fragment_header_a.fragment_size == fragment_header_b.fragment_size
	equal_fragment_id := fragment_header_a.fragment_id == fragment_header_b.fragment_id
	equal_num_fragments := fragment_header_a.num_fragments == fragment_header_b.num_fragments
	return equal_fragment_size && equal_fragment_id && equal_num_fragments
}

@(require_results)
compare_fragment :: proc(fragment_a: Fragment, fragment_b: Fragment) -> bool {
	equal_fragment_header := compare_fragment_header(
		fragment_a.fragment_header,
		fragment_b.fragment_header,
	)
	equal_data := bytes.compare(fragment_a.data, fragment_b.data) == 0
	return equal_fragment_header && equal_data

}

// ------------- Tests -------------

@(test)
test_serialize_deserialize_packet_header :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	packet_header := Packet_Header {
		crc32       = 72,
		packet_type = u32(Packet_Type.Test_B),
		data_length = 14,
		sequence    = 42,
	}

	testing.expectf(
		t,
		serialize_packet_header(&writer, packet_header),
		"serialize_packet_header should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_packet_header, des_packet_header_ok := deserialize_packet_header(&reader)

	testing.expectf(t, des_packet_header_ok, "deserialize_packet_header should be successful")

	testing.expect_value(t, des_packet_header, packet_header)
}

@(test)
test_serialize_deserialize_packet :: proc(t: ^testing.T) {

	buffer := make([]u32, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)

	writer := create_writer(buffer)
	reader := create_reader(buffer)

	data := make([]u8, 100, context.temp_allocator)
	for &b in data {
		b = 42
	}

	packet_header := Packet_Header {
		crc32       = 72,
		packet_type = u32(Packet_Type.Test_B),
		data_length = u32(len(data)),
		sequence    = 42,
	}

	packet := Packet{packet_header, data}

	testing.expectf(t, serialize_packet(&writer, packet), "serialize_packet should be successful")

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_packet, des_packet_ok := deserialize_packet(&reader, context.temp_allocator)

	testing.expectf(t, des_packet_ok, "deserialize_packet should be successful")

	testing.expectf(
		t,
		compare_packet(des_packet, packet),
		fmt.tprintf("expected %v to be equal to %v", packet, des_packet),
	)
}

@(test)
test_serialize_deserialize_fragment :: proc(t: ^testing.T) {

	buffer := make([]u32, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)

	writer := create_writer(buffer)
	reader := create_reader(buffer)

	data := make([]u8, 100, context.temp_allocator)
	for &b in data {
		b = 42
	}

	fragment := Fragment {
		fragment_header = Fragment_Header {
			fragment_size = u32(len(data)),
			fragment_id = 14,
			num_fragments = 53,
		},
		data = data,
	}

	testing.expectf(
		t,
		serialize_fragment(&writer, fragment),
		"serialize_fragment should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_fragment, des_fragment_ok := deserialize_fragment(&reader, context.temp_allocator)

	testing.expectf(t, des_fragment_ok, "deserialize_fragment should be successful")

	testing.expectf(
		t,
		compare_fragment(des_fragment, fragment),
		fmt.tprintf("expected %v to be equal to %v", fragment, des_fragment),
	)
}

@(test)
test_init_packet_buffer :: proc(t: ^testing.T) {
	packet_buffer, err := new(Packet_Buffer)
	assert(err == nil)
	defer free(packet_buffer)
	for entry in packet_buffer.entries {
		testing.expect_value(t, entry.sequence, 0)
	}

	init_packet_buffer(packet_buffer)

	for entry in packet_buffer.entries {
		testing.expect_value(t, entry.sequence, ENTRY_SENTINEL_VALUE)
	}
}

@(test)
test_split_packet_into_one_fragment_exact :: proc(t: ^testing.T) {
	packet_size := 1024
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(0, packet_data, context.temp_allocator)

	testing.expect_value(t, len(fragments), 1)
	for fragment, i in fragments {
		testing.expect_value(t, fragment.fragment_header.fragment_size, MAX_FRAGMENT_SIZE)
		testing.expect_value(t, fragment.fragment_header.fragment_id, u8(i))
		testing.expect_value(t, fragment.fragment_header.num_fragments, u8(len(fragments)))
	}
}

@(test)
test_split_packet_into_fragments_exact :: proc(t: ^testing.T) {

	packet_size := 2048
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(0, packet_data, context.temp_allocator)

	testing.expect_value(t, len(fragments), packet_size / MAX_FRAGMENT_SIZE)
	for fragment, i in fragments {
		testing.expect_value(t, fragment.fragment_header.fragment_size, MAX_FRAGMENT_SIZE)
		testing.expect_value(t, fragment.fragment_header.fragment_id, u8(i))
		testing.expect_value(t, fragment.fragment_header.num_fragments, u8(len(fragments)))
	}
}

@(test)
test_split_packet_into_fragments_one_remainder :: proc(t: ^testing.T) {

	packet_size := 2049
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(0, packet_data, context.temp_allocator)

	testing.expect_value(t, len(fragments), (packet_size / MAX_FRAGMENT_SIZE) + 1)

	for fragment, i in fragments {
		if i == len(fragments) - 1 {
			testing.expect_value(t, fragment.fragment_header.fragment_size, 1)
		} else {
			testing.expect_value(t, fragment.fragment_header.fragment_size, MAX_FRAGMENT_SIZE)
		}
		testing.expect_value(t, fragment.fragment_header.fragment_id, u8(i))
		testing.expect_value(t, fragment.fragment_header.num_fragments, u8(len(fragments)))
	}
}

@(test)
test_split_byte_buffer_multiple_fragment_packets :: proc(t: ^testing.T) {
	num_fragments := 8
	byte_buffer := make([]u8, num_fragments * MAX_FRAGMENT_SIZE, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for &b in byte_buffer {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}
	fragments := split_packet_into_fragments(0, byte_buffer, context.temp_allocator)
	testing.expect_value(t, len(fragments), num_fragments)

	for fragment, frag_idx in fragments {
		for i in 0 ..< len(fragment.data) {
			testing.expect_value(
				t,
				fragment.data[i],
				byte_buffer[frag_idx * MAX_FRAGMENT_SIZE + i],
			)
		}
	}
}

@(test)
test_serialize_split_and_reassemble_and_deserialize_test_packet :: proc(t: ^testing.T) {
	test_packet := random_test_packet_b()
	buffer := make([]u32, 2048, context.temp_allocator)
	defer free_all(context.temp_allocator)
	writer := create_writer(buffer)

	testing.expectf(
		t,
		serialize_test_packet_b(&writer, test_packet),
		"serializing test packet should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flushing test packet writer should be successful")

	fragments := split_packet_into_fragments(
		0,
		convert_word_slice_to_byte_slice(writer.buffer),
		context.temp_allocator,
	)
	testing.expect_value(t, len(fragments), 8)

	fragment_data_buffer := make([]u8, 2048 * size_of(u32), context.temp_allocator)

	for fragment, i in fragments {
		testing.expect_value(t, fragment.fragment_header.fragment_size, MAX_FRAGMENT_SIZE)
		testing.expect_value(t, fragment.fragment_header.fragment_id, u8(i))
		testing.expect_value(t, fragment.fragment_header.num_fragments, u8(len(fragments)))

		mem.copy(
			&fragment_data_buffer[int(fragment.fragment_header.fragment_id) * MAX_FRAGMENT_SIZE],
			&fragment.data[0],
			len(fragment.data),
		)
	}

	fragment_data_buffer_words := convert_byte_slice_to_word_slice(fragment_data_buffer)
	reader := create_reader(fragment_data_buffer_words)
	des_test_packet, ok := deserialize_test_packet_b(&reader)
	testing.expectf(t, ok, "deserializing test packet should be successful")

	testing.expect_value(t, test_packet, des_test_packet)
}

@(test)
test_process_fragment :: proc(t: ^testing.T) {
	packet_buffer := new(Packet_Buffer, context.temp_allocator)
	defer free_all(context.temp_allocator)
	init_packet_buffer(packet_buffer)

	fragment_data := make([]u8, MAX_FRAGMENT_SIZE, context.temp_allocator)

	for &b in fragment_data {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}

	sequence: u16 = 0
	fragment_id: u8 = 0
	num_fragments: u8 = 1

	fragment := Fragment {
		fragment_header = Fragment_Header {
			fragment_size = MAX_FRAGMENT_SIZE,
			fragment_id = fragment_id,
			num_fragments = num_fragments,
		},
		data = fragment_data,
	}


	testing.expectf(
		t,
		process_fragment(
			packet_buffer,
			sequence,
			Packet_Type.Test_B,
			fragment,
			context.temp_allocator,
		),
		"processing fragment packet should be successful",
	)

	fragment_entry := packet_buffer.entries[sequence].entry.(Fragment_Entry)

	testing.expect_value(t, fragment_entry.num_fragments, fragment.fragment_header.num_fragments)

	for i in 0 ..< len(fragment_entry.fragments[0]) {
		testing.expect_value(t, fragment_entry.fragments[0][i], fragment_data[i])
	}
}

@(test)
test_process_multiple_fragments :: proc(t: ^testing.T) {
	packet_buffer := new(Packet_Buffer, context.temp_allocator)
	defer free_all(context.temp_allocator)

	init_packet_buffer(packet_buffer)

	num_fragments := 8
	packet_data := make([]u8, num_fragments * MAX_FRAGMENT_SIZE, context.temp_allocator)
	for &b in packet_data {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}

	sequence: u16 = 0

	fragments := split_packet_into_fragments(sequence, packet_data, context.temp_allocator)


	for fragment in fragments {
		testing.expectf(
			t,
			process_fragment(
				packet_buffer,
				sequence,
				Packet_Type.Test_B,
				fragment,
				context.temp_allocator,
			),
			"process_fragment should be successful",
		)
	}

	fragment_entry := packet_buffer.entries[sequence].entry.(Fragment_Entry)
	for frag_idx in 0 ..< num_fragments {
		for i in 0 ..< len(fragment_entry.fragments[frag_idx]) {
			testing.expect_value(
				t,
				packet_data[frag_idx * MAX_FRAGMENT_SIZE + i],
				fragment_entry.fragments[frag_idx][i],
			)
		}
	}
}

@(test)
test_process_packet_and_receive_fragments :: proc(t: ^testing.T) {
	packet_buffer := new(Packet_Buffer, context.temp_allocator)
	defer free_all(context.temp_allocator)
	init_packet_buffer(packet_buffer)
	sequence: u32 = 0

	test_packet := random_test_packet_b()

	writer_buffer := make([]u32, 2048, context.temp_allocator)
	writer := create_writer(writer_buffer)

	testing.expectf(
		t,
		serialize_test_packet_b(&writer, test_packet),
		"serialize_test_packet should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	fragments := split_packet_into_fragments(
		u16(sequence),
		convert_word_slice_to_byte_slice(writer.buffer),
		context.temp_allocator,
	)

	num_fragments := len(fragments)
	testing.expect_value(t, num_fragments, 8)

	for fragment in fragments {
		fragment_writer_buffer_size := (size_of(Fragment_Header) + MAX_FRAGMENT_SIZE)
		fragment_writer_buffer := make(
			[]u32,
			fragment_writer_buffer_size / size_of(u32),
			context.temp_allocator,
		)

		fragment_writer := create_writer(fragment_writer_buffer)

		testing.expectf(
			t,
			serialize_fragment(&fragment_writer, fragment),
			"serialize_fragment should be successful",
		)

		testing.expectf(t, flush_bits(&fragment_writer), "flush_bits should be successful")

		packet_writer_buffer := make(
			[]u32,
			(size_of(Packet_Header) + fragment_writer_buffer_size) / size_of(u32),
			context.temp_allocator,
		)

		packet_writer := create_writer(packet_writer_buffer)

		packet_header := Packet_Header {
			crc32       = 42,
			packet_type = u32(Packet_Type.Test_B),
			data_length = u32(fragment_writer_buffer_size),
			sequence    = 0,
			is_fragment = true,
		}

		testing.expectf(
			t,
			serialize_packet_from_header_and_byte_slice(
				&packet_writer,
				packet_header,
				convert_word_slice_to_byte_slice(fragment_writer.buffer),
			),
			"serialize_packet_from_header_and_byte_slice should be successful",
		)

		testing.expectf(t, flush_bits(&packet_writer), "flush_bits should be successful")

		testing.expectf(
			t,
			process_packet(
				packet_buffer,
				convert_word_slice_to_byte_slice(packet_writer.buffer),
				context.temp_allocator,
			),
			"process_packet should be successful",
		)
	}

	packet_type, packet_data, receive_fragments_ok := receive_fragments(
		packet_buffer,
		sequence,
		context.temp_allocator,
	)

	testing.expectf(t, receive_fragments_ok, "receive_fragments should be successful")
	testing.expect_value(t, packet_type, Packet_Type.Test_B)


	if packet_type == Packet_Type.Test_B {
		test_packet_reader := create_reader(convert_byte_slice_to_word_slice(packet_data))
		des_test_packet, des_test_packet_ok := deserialize_test_packet_b(&test_packet_reader)
		testing.expectf(t, des_test_packet_ok, "deserialize_test_packet should be successful")
		testing.expect_value(t, des_test_packet, test_packet)
	}
}
