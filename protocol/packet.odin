package protocol

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"

MAX_FRAGMENTS_PER_PACKET :: 256
MAX_FRAGMENT_SIZE :: 1024
MAX_PACKET_SIZE :: MAX_FRAGMENTS_PER_PACKET * MAX_FRAGMENT_SIZE

// TODO(Thomas): Thinks about whether this more than one
// variant restriction is just too fallible
// NOTE(Thomas): Serialization and de-serialization
// requires this to have more than one variant
Packet_Type :: enum {
	Fragment,
	Test_Packet_A,
	Test_Packet_B,
}

Test_Packet_A :: struct {
	a: i32,
	b: i32,
	c: i32,
}

serialize_test_packet_a :: proc(
	bit_writer: ^Bit_Writer,
	test_packet: Test_Packet_A,
) -> bool {
	if !serialize_integer(
		bit_writer,
		test_packet.a,
		math.min(i32),
		math.max(i32),
	) {
		return false
	}

	if !serialize_integer(
		bit_writer,
		test_packet.b,
		math.min(i32),
		math.max(i32),
	) {
		return false
	}

	if !serialize_integer(
		bit_writer,
		test_packet.c,
		math.min(i32),
		math.max(i32),
	) {
		return false
	}

	return true
}

deserialize_test_packet_a :: proc(
	bit_reader: ^Bit_Reader,
) -> (
	Test_Packet_A,
	bool,
) {
	test_packet := Test_Packet_A{}

	a, a_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !a_ok {
		return Test_Packet_A{}, false
	}

	b, b_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !b_ok {
		return Test_Packet_A{}, false
	}

	c, c_ok := deserialize_integer(bit_reader, math.min(i32), math.max(i32))
	if !c_ok {
		return Test_Packet_A{}, false
	}

	return Test_Packet_A{a, b, c}, true
}

// Packet that should be larger than the MTU, so that we have to split it up into 
// mutlple Fragment_Packet, but smaller than the MAX_PACKET_SIZE.
Test_Packet_B :: struct {
	items: [2048]i32,
}

serialize_test_packet_b :: proc(
	bit_writer: ^Bit_Writer,
	test_packet: Test_Packet_B,
) -> bool {
	for item in test_packet.items {
		if !serialize_integer(bit_writer, item, math.min(i32), math.max(i32)) {
			return false
		}
	}

	return true
}

desserialize_test_packet_b :: proc(
	bit_reader: ^Bit_Reader,
) -> (
	Test_Packet_B,
	bool,
) {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		item, ok := deserialize_integer(
			bit_reader,
			math.min(i32),
			math.max(i32),
		)
		if !ok {
			return Test_Packet_B{}, false
		}
		test_packet.items[i] = item
	}

	return test_packet, true
}

random_test_packet_b :: proc() -> Test_Packet_B {
	test_packet := Test_Packet_B{}
	for i in 0 ..< len(test_packet.items) {
		test_packet.items[i] = rand.int31()
	}
	return test_packet
}

Packet_Header :: struct {
	crc32:       u32,
	packet_type: i32,
	sequence:    u16,
}

FRAGMENT_PACKET_HEADER_SIZE :: offset_of(Fragment_Packet, data)

Fragment_Packet :: struct {
	fragment_size: u32,
	packet_header: Packet_Header,
	fragment_id:   u8,
	num_fragments: u8,
	// Pad zero bits to nearest byte index
	data:          []u8,
}

MAX_ENTRIES :: 256

// Used to represent empty entries since it cannot occur
// by 16 bit sequence numbers.
ENTRY_SENTINEL_VALUE :: 0xFFFF_FFFF

Entry :: struct {
	num_fragments:      u8,
	received_fragments: u8,
	fragments:          [][]u8,
}

Sequence_Buffer :: struct {
	current_sequence: u32,
	sequence:         [MAX_ENTRIES]u32,
	entries:          [MAX_ENTRIES]Entry,
}

// Since initially every entry in the Sequence_Buffer is empty, we set
// all sequences to be the ENTRY_SENTINEL_VALUE
init_sequence_buffer :: proc(sequence_buffer: ^Sequence_Buffer) {
	for &sequence in sequence_buffer.sequence {
		sequence = ENTRY_SENTINEL_VALUE
	}
}

get_sequence_index :: proc(sequence: u16) -> i32 {
	return i32(sequence % MAX_ENTRIES)
}

// Advances the current sequence number forward.
// TODO(Thomas): Needs to deal with wrapping sequence numbers
advance_sequence :: proc(sequence_buffer: ^Sequence_Buffer) {
	sequence_buffer.current_sequence += 1
}


// TODO(Thomas): Think about allocation here, this is where we need to free the fragments too?
// so we need an allocation strategy that only deallocates the fragments that have been reassembled
// The purpose of this procedure is to check if all fragments of a packet has been
// received, if it has, then we reassmble the original packet. This should again be called
// from another procedure that does for the the entire Sequence_Buffer
receive_packet_fragments :: proc(
	sequence_buffer: ^Sequence_Buffer,
	sequence: u32,
	allocator := context.temp_allocator,
) -> (
	[]u8,
	bool,
) {
	// check if the sequence is valid and set
	if sequence_buffer.sequence[sequence] != u32(sequence) {
		return nil, false
	}

	// get the entry
	entry := sequence_buffer.entries[sequence]

	// check if the amount of received fragments is equal to the amount of expected fragments
	if entry.received_fragments != entry.num_fragments {
		return nil, false
	}

	// calculate the total packet size
	total_packet_size := 0
	for fragment in entry.fragments {
		total_packet_size += len(fragment)
	}

	assert(total_packet_size > 0)
	assert(total_packet_size <= MAX_PACKET_SIZE)

	// reassemble the packet, just the bytes though
	packet_data := make([]u8, total_packet_size, allocator)
	current_memory_offset := 0
	for idx in 0 ..< entry.num_fragments {
		fragment := entry.fragments[idx]
		fragment_size := len(fragment)
		mem.copy(
			&packet_data[current_memory_offset],
			&fragment[0],
			fragment_size,
		)

		current_memory_offset += fragment_size
	}

	return packet_data, true
}

process_fragment :: proc(
	sequence_buffer: ^Sequence_Buffer,
	fragment_packet: Fragment_Packet,
	allocator := context.temp_allocator,
) -> bool {

	assert(len(fragment_packet.data) > 0)
	assert(len(fragment_packet.data) <= MAX_FRAGMENT_SIZE)
	index := get_sequence_index(fragment_packet.packet_header.sequence)

	if sequence_buffer.sequence[index] == ENTRY_SENTINEL_VALUE {

		data: [][]u8 = make([][]u8, MAX_FRAGMENTS_PER_PACKET, allocator)

		data[fragment_packet.fragment_id] = make(
			[]u8,
			fragment_packet.fragment_size,
			allocator,
		)

		sequence_buffer.entries[index] = Entry {
			num_fragments      = fragment_packet.num_fragments,
			received_fragments = 0,
			fragments          = data,
		}

		mem.copy(
			&sequence_buffer.entries[index].fragments[fragment_packet.fragment_id][0],
			&fragment_packet.data[0],
			len(fragment_packet.data),
		)

		sequence_buffer.entries[index].received_fragments += 1

		// TODO(Thomas): Is this correct??
		sequence_buffer.sequence[index] = u32(
			fragment_packet.packet_header.sequence,
		)
		sequence_buffer.current_sequence = u32(
			fragment_packet.packet_header.sequence,
		)

	} else {

		sequence_buffer.entries[index].fragments[fragment_packet.fragment_id] =
			make([]u8, fragment_packet.fragment_size, allocator)

		sequence_buffer.entries[index].received_fragments += 1

		sequence_buffer.entries[index].num_fragments =
			fragment_packet.num_fragments

		mem.copy(
			&sequence_buffer.entries[index].fragments[fragment_packet.fragment_id][0],
			&fragment_packet.data[0],
			len(fragment_packet.data),
		)

		// TODO(Thomas): Is this correct??
		sequence_buffer.sequence[index] = u32(
			fragment_packet.packet_header.sequence,
		)
		sequence_buffer.current_sequence = u32(
			fragment_packet.packet_header.sequence,
		)
	}

	return true
}

process_packet :: proc(
	sequence_buffer: ^Sequence_Buffer,
	data: []u8,
	allocator := context.temp_allocator,
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
	reader := create_reader(words)

	fragment_packet, ok := deserialize_fragment_packet(&reader)
	if !ok {
		return false
	}

	protocol_id := PROTOCOL_ID
	protocol_id_bytes := transmute([4]u8)protocol_id
	crc32 := calculate_crc32(protocol_id_bytes[:])

	// TODO(Thomas): Deal with crc32 calculation properly and compare the 
	// Packet crc32 to the one we've calculated here

	if fragment_packet.packet_header.packet_type == i32(Packet_Type.Fragment) {
		if !process_fragment(sequence_buffer, fragment_packet, allocator) {
			return false
		}
	} else {
		// TODO(Thomas): What to do here??
	}


	return true
}

// TODO(Thomas): Better suited default allocator?
split_packet_into_fragments :: proc(
	sequence: u16,
	packet_data: []u8,
	allocator := context.temp_allocator,
) -> []Fragment_Packet {

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

	fragments := make([]Fragment_Packet, num_fragments, allocator)

	for &fragment, i in fragments {

		fragment_size := MAX_FRAGMENT_SIZE

		// The case where packet_size / MAX_FRAGMENT_SIZE does not divide evenly, we get a
		// remainder which will be the size of the last packet.
		if remainder != 0 && i == int(num_fragments) - 1 {
			fragment_size = int(remainder)
		}

		fragment.data = make([]u8, MAX_FRAGMENT_SIZE, allocator)

		mem.copy(
			&fragment.data[0],
			&packet_data[i * fragment_size],
			fragment_size,
		)

		fragment.fragment_size = u32(fragment_size)
		fragment.packet_header = Packet_Header {
			crc32       = calculate_crc32(fragment.data),
			packet_type = i32(Packet_Type.Fragment),
			sequence    = sequence,
		}
		fragment.fragment_id = u8(i)
		fragment.num_fragments = u8(num_fragments)
	}

	return fragments
}

serialize_packet_header :: proc(
	bit_writer: ^Bit_Writer,
	packet_header: Packet_Header,
) -> bool {
	if !write_bits(bit_writer, packet_header.crc32, 32) {
		return false
	}

	// NOTE(Thomas): This len(Packet_Type) - 1 trick only works if 
	// there is more than one variant in the Packet_Type enum
	if !write_bits(
		bit_writer,
		u32(packet_header.packet_type),
		len(Packet_Type) - 1,
	) {
		return false
	}

	if !write_bits(bit_writer, u32(packet_header.sequence), 32) {
		return false
	}

	return true
}

serialize_fragment_packet :: proc(
	bit_writer: ^Bit_Writer,
	fragment_packet: Fragment_Packet,
) -> bool {

	if !write_bits(bit_writer, fragment_packet.fragment_size, 32) {
		return false
	}

	if !serialize_packet_header(bit_writer, fragment_packet.packet_header) {
		return false
	}

	if !write_bits(bit_writer, u32(fragment_packet.fragment_id), 8) {
		return false
	}

	if !write_bits(bit_writer, u32(fragment_packet.num_fragments), 8) {
		return false
	}

	// Ensure alignment to byte index, so we can simply calculate the fragment size
	if !serialize_align(bit_writer) {
		return false
	}

	assert(fragment_packet.fragment_size > 0)
	assert(fragment_packet.fragment_size <= MAX_FRAGMENT_SIZE)

	assert(len(fragment_packet.data) <= int(fragment_packet.fragment_size))

	if !serialize_bytes(bit_writer, fragment_packet.data[:]) {
		return false
	}

	return true
}

// TODO(Thomas): Add unit tests
serialize_fragment_packets :: proc(
	bit_writer: ^Bit_Writer,
	fragment_packets: []Fragment_Packet,
) -> bool {
	for fragment in fragment_packets {
		if !serialize_fragment_packet(bit_writer, fragment) {
			return false
		}
	}

	return true
}

deserialize_packet_header :: proc(
	bit_reader: ^Bit_Reader,
) -> (
	Packet_Header,
	bool,
) {

	crc32, crc32_ok := read_bits(bit_reader, 32)
	if !crc32_ok {
		return Packet_Header{}, false
	}

	packet_type, packet_type_ok := read_bits(bit_reader, len(Packet_Type) - 1)
	if !packet_type_ok {
		return Packet_Header{}, false
	}

	sequence, seq_ok := read_bits(bit_reader, 32)
	if !seq_ok {
		return Packet_Header{}, false
	}

	return Packet_Header{crc32, i32(packet_type), u16(sequence)}, true
}

deserialize_fragment_packet :: proc(
	bit_reader: ^Bit_Reader,
	allocator := context.temp_allocator,
) -> (
	Fragment_Packet,
	bool,
) {
	fragment_size, fragment_size_ok := read_bits(bit_reader, 32)
	if !fragment_size_ok {
		return Fragment_Packet{}, false
	}

	if fragment_size <= 0 || fragment_size > MAX_FRAGMENT_SIZE {
		log.errorf("packet fragment size is out of bounds: %v", fragment_size)
		return Fragment_Packet{}, false
	}

	packet_header, packet_header_ok := deserialize_packet_header(bit_reader)
	if !packet_header_ok {
		return Fragment_Packet{}, false
	}

	fragment_id, fragment_id_ok := read_bits(bit_reader, 8)
	if !fragment_id_ok {
		return Fragment_Packet{}, false
	}

	num_fragments, num_fragments_ok := read_bits(bit_reader, 8)
	if !num_fragments_ok {
		return Fragment_Packet{}, false
	}

	align_ok := deserialize_align(bit_reader)
	if !align_ok {
		return Fragment_Packet{}, false
	}

	data := make([]u8, fragment_size, allocator)
	data_ok := read_bytes(bit_reader, data, fragment_size)
	if !data_ok {
		return Fragment_Packet{}, false
	}

	return Fragment_Packet {
			fragment_size,
			packet_header,
			u8(fragment_id),
			u8(num_fragments),
			data,
		},
		true
}


compare_fragment_packet :: proc(
	packet_a: Fragment_Packet,
	packet_b: Fragment_Packet,
) -> bool {
	equal_frag_size := packet_a.fragment_size == packet_b.fragment_size
	equal_packet_header := packet_a.packet_header == packet_b.packet_header
	equal_frag_id := packet_a.fragment_id == packet_b.fragment_id
	equal_num_fragments := packet_a.num_fragments == packet_b.num_fragments
	equal_data := bytes.compare(packet_a.data, packet_b.data) == 0
	return(
		equal_frag_size &&
		equal_packet_header &&
		equal_frag_id &&
		equal_num_fragments &&
		equal_data \
	)
}

@(test)
test_compare_fragment_packet :: proc(t: ^testing.T) {
	// Test Case 1: Compare against self
	{
		fragment_data: [MAX_FRAGMENT_SIZE]u8
		fragment_packet := Fragment_Packet {
			fragment_size = MAX_FRAGMENT_SIZE,
			packet_header = Packet_Header {
				crc32 = 72,
				sequence = 42,
				packet_type = i32(Packet_Type.Fragment),
			},
			fragment_id = 12,
			num_fragments = 14,
			data = fragment_data[:],
		}

		equal_packets := compare_fragment_packet(
			fragment_packet,
			fragment_packet,
		)
		testing.expectf(
			t,
			equal_packets,
			fmt.tprintf(
				"Compare fragment packet should return true for itself",
			),
		)
	}

	// Test Case 2: Not equal
	{

		fragment_data: [MAX_FRAGMENT_SIZE]u8
		fragment_packet_a := Fragment_Packet {
			fragment_size = MAX_FRAGMENT_SIZE,
			packet_header = Packet_Header {
				crc32 = 72,
				sequence = 42,
				packet_type = i32(Packet_Type.Fragment),
			},
			fragment_id = 12,
			num_fragments = 14,
			data = fragment_data[:],
		}
		fragment_packet_b := Fragment_Packet {
			fragment_size = MAX_FRAGMENT_SIZE,
			packet_header = Packet_Header {
				crc32 = 72,
				sequence = 42,
				packet_type = i32(Packet_Type.Fragment),
			},
			num_fragments = 14,
			data = fragment_data[:],
		}

		equal_packets := compare_fragment_packet(
			fragment_packet_a,
			fragment_packet_b,
		)

		testing.expectf(
			t,
			!equal_packets,
			fmt.tprintf(
				"fragment_packet_a and fragment_packet_b should not be equal",
			),
		)
	}
}

@(test)
test_serialize_deserialize_fragment_packet_max_size :: proc(t: ^testing.T) {
	buffer := make([]u32, MAX_PACKET_SIZE / 4, context.temp_allocator)
	defer free_all(context.temp_allocator)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	fragment_data: [MAX_FRAGMENT_SIZE]u8
	fragment_packet := Fragment_Packet {
		fragment_size = MAX_FRAGMENT_SIZE,
		packet_header = Packet_Header {
			crc32 = 72,
			sequence = 42,
			packet_type = i32(Packet_Type.Fragment),
		},
		fragment_id = 12,
		num_fragments = 14,
		data = fragment_data[:],
	}
	serialize_ok := serialize_fragment_packet(&writer, fragment_packet)
	testing.expectf(
		t,
		serialize_ok,
		fmt.tprintf("serializing fragment packet should be ok"),
	)

	flush_ok := flush_bits(&writer)
	testing.expectf(t, flush_ok, fmt.tprintf("flushing writer should be ok"))

	deserialized_fragment_packet, deserialize_ok :=
		deserialize_fragment_packet(&reader, context.temp_allocator)
	testing.expectf(
		t,
		deserialize_ok,
		fmt.tprintf("deserializing fragment packet should be ok"),
	)

	testing.expectf(
		t,
		compare_fragment_packet(fragment_packet, deserialized_fragment_packet),
		"expected fragment_packet and deserialized_fragment_packet to be qual, but they were not",
	)
}

@(test)
test_serialize_deserialize_fragment_packet_medium_size :: proc(t: ^testing.T) {
	buffer := make([]u32, MAX_PACKET_SIZE / 4, context.temp_allocator)
	defer free_all(context.temp_allocator)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	fragment_data: [MAX_FRAGMENT_SIZE / 2]u8
	fragment_packet := Fragment_Packet {
			fragment_size = MAX_FRAGMENT_SIZE / 2,
			packet_header = Packet_Header {
				crc32 = 72,
				packet_type = i32(Packet_Type.Fragment),
				sequence = 42,
			},
			fragment_id = 12,
			num_fragments = 14,
			data = fragment_data[:],
		}
	serialize_ok := serialize_fragment_packet(&writer, fragment_packet)
	testing.expectf(
		t,
		serialize_ok,
		fmt.tprintf("serializing fragment packet should be ok"),
	)

	flush_ok := flush_bits(&writer)
	testing.expectf(t, flush_ok, fmt.tprintf("flushing writer should be ok"))

	deserialized_fragment_packet, deserialize_ok :=
		deserialize_fragment_packet(&reader, context.temp_allocator)
	testing.expectf(
		t,
		deserialize_ok,
		fmt.tprintf("deserializing fragment packet should be ok"),
	)

	testing.expectf(
		t,
		compare_fragment_packet(fragment_packet, deserialized_fragment_packet),
		"expected fragment_packet and deserialized_fragment_packet to be qual, but they were not",
	)
}

@(test)
test_init_sequence_buffer :: proc(t: ^testing.T) {
	seq_buffer, err := new(Sequence_Buffer)
	assert(err == nil)
	defer free(seq_buffer)
	for seq in seq_buffer.sequence {
		testing.expect_value(t, seq, 0)
	}

	init_sequence_buffer(seq_buffer)

	for seq in seq_buffer.sequence {
		testing.expect_value(t, seq, ENTRY_SENTINEL_VALUE)
	}
}

@(test)
test_serialize_deserialize_test_packet :: proc(t: ^testing.T) {
	buffer := make([]u32, 2048)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	test_packet := random_test_packet_b()
	serialize_ok := serialize_test_packet_b(&writer, test_packet)

	testing.expectf(
		t,
		serialize_ok,
		fmt.tprintf("Serializing test packet should be successful"),
	)

	deserialized_test_packet, deserialize_ok := desserialize_test_packet_b(
		&reader,
	)
	testing.expectf(
		t,
		deserialize_ok,
		fmt.tprintf("Deserializing test packet should be successful"),
	)

	testing.expect_value(t, deserialized_test_packet, test_packet)
}

@(test)
test_split_packet_into_one_fragment_exact :: proc(t: ^testing.T) {
	packet_size := 1024
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(
		0,
		packet_data,
		context.temp_allocator,
	)

	testing.expect_value(t, len(fragments), 1)
	for fragment in fragments {
		testing.expect_value(t, fragment.fragment_size, MAX_FRAGMENT_SIZE)
	}
}

@(test)
test_split_packet_into_fragments_exact :: proc(t: ^testing.T) {

	packet_size := 2048
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(
		0,
		packet_data,
		context.temp_allocator,
	)

	testing.expect_value(t, len(fragments), packet_size / MAX_FRAGMENT_SIZE)
	for fragment in fragments {
		testing.expect_value(t, fragment.fragment_size, MAX_FRAGMENT_SIZE)
	}
}

@(test)
test_split_packet_into_fragments_one_remainder :: proc(t: ^testing.T) {

	packet_size := 2049
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	fragments := split_packet_into_fragments(
		0,
		packet_data,
		context.temp_allocator,
	)

	testing.expect_value(
		t,
		len(fragments),
		(packet_size / MAX_FRAGMENT_SIZE) + 1,
	)

	for fragment, i in fragments {
		if i == len(fragments) - 1 {
			testing.expect_value(t, fragment.fragment_size, 1)
		} else {
			testing.expect_value(t, fragment.fragment_size, MAX_FRAGMENT_SIZE)
		}
	}
}

@(test)
test_split_byte_buffer_single_fragment_packet :: proc(t: ^testing.T) {
	num_fragments := 1
	byte_buffer := make([]u8, MAX_FRAGMENT_SIZE)
	defer delete(byte_buffer)
	for &b in byte_buffer {
		b = u8(rand.int_max(256))
	}

	fragments := split_packet_into_fragments(0, byte_buffer)
	testing.expect_value(t, len(fragments), num_fragments)
	fragment := fragments[0]
	testing.expect_value(t, fragment.fragment_size, MAX_FRAGMENT_SIZE)
	for i in 0 ..< len(fragment.data) {
		testing.expect_value(t, fragment.data[i], byte_buffer[i])
	}

}

@(test)
test_split_byte_buffer_multiple_fragment_packets :: proc(t: ^testing.T) {
	num_fragments := 8
	byte_buffer := make([]u8, num_fragments * MAX_FRAGMENT_SIZE)
	defer delete(byte_buffer)
	for &b in byte_buffer {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}
	fragments := split_packet_into_fragments(0, byte_buffer)
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
test_serialize_split_and_reassemble_and_deserialize_test_packet :: proc(
	t: ^testing.T,
) {
	test_packet := random_test_packet_b()
	buffer := make([]u32, 2048)
	defer delete(buffer)
	writer := create_writer(buffer)

	testing.expectf(
		t,
		serialize_test_packet_b(&writer, test_packet),
		"serializing test packet should be successful",
	)

	testing.expectf(
		t,
		flush_bits(&writer),
		"flusing test packet writer should be successful",
	)

	fragments := split_packet_into_fragments(
		0,
		convert_word_slice_to_byte_slice(writer.buffer),
	)
	testing.expect_value(t, len(fragments), 8)

	fragment_data_buffer := make([]u8, 2048 * size_of(u32))
	defer delete(fragment_data_buffer)

	for fragment in fragments {
		testing.expect_value(t, fragment.fragment_size, MAX_FRAGMENT_SIZE)

		mem.copy(
			&fragment_data_buffer[int(fragment.fragment_id) * MAX_FRAGMENT_SIZE],
			&fragment.data[0],
			len(fragment.data),
		)
	}

	fragment_data_buffer_words := convert_byte_slice_to_word_slice(
		fragment_data_buffer,
	)
	reader := create_reader(fragment_data_buffer_words)
	des_test_packet, ok := desserialize_test_packet_b(&reader)
	testing.expectf(t, ok, "deserializing test packet should be successful")

	testing.expect_value(t, test_packet, des_test_packet)
}

@(test)
test_process_fragment :: proc(t: ^testing.T) {
	sequence_buffer := new(Sequence_Buffer)
	defer free(sequence_buffer)
	init_sequence_buffer(sequence_buffer)


	fragment_data := make([]u8, MAX_FRAGMENT_SIZE)
	defer delete(fragment_data)

	for &b in fragment_data {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}

	fragment_packet := Fragment_Packet {
		packet_header = Packet_Header {
			crc32 = 0,
			sequence = 0,
			packet_type = i32(Packet_Type.Fragment),
		},
		fragment_id = 0,
		fragment_size = MAX_FRAGMENT_SIZE,
		data = fragment_data,
	}

	testing.expectf(
		t,
		process_fragment(sequence_buffer, fragment_packet),
		"processing fragment packet should be successful",
	)
	defer free_all(context.temp_allocator)

	for i in 0 ..< len(sequence_buffer.entries[0].fragments[0]) {
		testing.expect_value(
			t,
			sequence_buffer.entries[0].fragments[0][i],
			fragment_data[i],
		)
	}
}

@(test)
test_process_multiple_fragments :: proc(t: ^testing.T) {
	sequence_buffer := new(Sequence_Buffer)
	defer free(sequence_buffer)
	init_sequence_buffer(sequence_buffer)

	num_fragments := 8
	packet_data := make([]u8, num_fragments * MAX_FRAGMENT_SIZE)
	for &b in packet_data {
		b = u8(rand.int31_max(i32(math.max(u8)) + 1))
	}
	defer delete(packet_data)
	fragments := split_packet_into_fragments(0, packet_data)

	for fragment in fragments {
		testing.expectf(
			t,
			process_fragment(sequence_buffer, fragment),
			"process_fragment should be successful",
		)
	}
	defer free_all(context.temp_allocator)

	for frag_idx in 0 ..< num_fragments {
		for i in 0 ..< len(sequence_buffer.entries[0].fragments[frag_idx]) {
			testing.expect_value(
				t,
				packet_data[frag_idx * MAX_FRAGMENT_SIZE + i],
				sequence_buffer.entries[0].fragments[frag_idx][i],
			)
		}
	}
}

@(test)
test_process_packet :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	sequence_buffer := new(Sequence_Buffer)
	defer free(sequence_buffer)
	init_sequence_buffer(sequence_buffer)
	sequence: u32 = 0

	test_packet := random_test_packet_b()

	writer_buffer := make([]u32, 2048)
	defer delete(writer_buffer)
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
	)

	num_fragments := len(fragments)
	testing.expect_value(t, num_fragments, 8)

	for fragment in fragments {
		fragment_writer_buffer := make(
			[]u32,
			(FRAGMENT_PACKET_HEADER_SIZE + MAX_FRAGMENT_SIZE) / size_of(u32),
			context.temp_allocator,
		)

		fragment_writer := create_writer(fragment_writer_buffer)

		testing.expectf(
			t,
			serialize_fragment_packet(&fragment_writer, fragment),
			"serializing_fragment_packet should be successful",
		)

		testing.expectf(
			t,
			flush_bits(&fragment_writer),
			"flush_bits should be successful",
		)

		testing.expectf(
			t,
			process_packet(
				sequence_buffer,
				convert_word_slice_to_byte_slice(fragment_writer_buffer),
			),
			"process_packet should be successful",
		)
	}

	// Reassemble all the fragment data into a single buffer
	reassembled_test_packet_data := make([]u8, 2048 * size_of(u32))
	defer delete(reassembled_test_packet_data)
	for frag_idx in 0 ..< num_fragments {
		mem.copy(
			&reassembled_test_packet_data[frag_idx * MAX_FRAGMENT_SIZE],
			&sequence_buffer.entries[0].fragments[frag_idx][0],
			MAX_FRAGMENT_SIZE,
		)
	}
	reassembled_test_packet_reader := create_reader(
		convert_byte_slice_to_word_slice(reassembled_test_packet_data),
	)

	des_test_packet, des_test_packet_ok := desserialize_test_packet_b(
		&reassembled_test_packet_reader,
	)

	testing.expectf(
		t,
		des_test_packet_ok,
		"deseriaize_test_packet should be successful",
	)

	testing.expect_value(t, des_test_packet, test_packet)

	// assert state of the Sequence_Buffer
	testing.expect_value(t, sequence_buffer.current_sequence, sequence)
	for seq, i in sequence_buffer.sequence {
		if i == 0 {
			testing.expect_value(t, seq, sequence)
		} else {
			testing.expect_value(t, seq, ENTRY_SENTINEL_VALUE)
		}
	}

	for entry, i in sequence_buffer.entries {
		if i == int(sequence) {
			testing.expect_value(t, entry.num_fragments, u8(num_fragments))
			testing.expect_value(
				t,
				entry.received_fragments,
				u8(num_fragments),
			)
		} else {
			testing.expect_value(t, entry.num_fragments, 0)
			testing.expect_value(t, entry.received_fragments, 0)
		}
	}
}

@(test)
test_receive_packet_fragments :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sequence_buffer := new(Sequence_Buffer)
	defer free(sequence_buffer)
	init_sequence_buffer(sequence_buffer)

	sequence: u32 = 0
	test_packet := random_test_packet_b()

	writer_buffer := make([]u32, 2048)
	defer delete(writer_buffer)
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
	)

	num_fragments := len(fragments)
	testing.expect_value(t, num_fragments, 8)

	for fragment in fragments {
		fragment_writer_buffer := make(
			[]u32,
			(FRAGMENT_PACKET_HEADER_SIZE + MAX_FRAGMENT_SIZE) / size_of(u32),
			context.temp_allocator,
		)

		fragment_writer := create_writer(fragment_writer_buffer)

		testing.expectf(
			t,
			serialize_fragment_packet(&fragment_writer, fragment),
			"serializing_fragment_packet should be successful",
		)

		testing.expectf(
			t,
			flush_bits(&fragment_writer),
			"flush_bits should be successful",
		)

		testing.expectf(
			t,
			process_packet(
				sequence_buffer,
				convert_word_slice_to_byte_slice(fragment_writer_buffer),
			),
			"process_packet should be successful",
		)
	}

	packet_data, receive_packet_fragments_ok := receive_packet_fragments(
		sequence_buffer,
		sequence,
		context.temp_allocator,
	)

	testing.expectf(
		t,
		receive_packet_fragments_ok,
		"receive_packet_fragments should be successful",
	)

	test_packet_reader := create_reader(
		convert_byte_slice_to_word_slice(packet_data),
	)

	des_test_packet, des_test_packet_ok := desserialize_test_packet_b(
		&test_packet_reader,
	)

	testing.expectf(
		t,
		des_test_packet_ok,
		"deserialize_test_packet should be successful",
	)

	testing.expect_value(t, des_test_packet, test_packet)
}
