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
	TestPacket,
}

// Packet that should be larger than the MTU, so that we have to split it up into 
// mutlple Fragment_Packet, but smaller than the MAX_PACKET_SIZE.
TestPacket :: struct {
	items: [2048]i32,
}

serialize_test_packet :: proc(
	bit_writer: ^Bit_Writer,
	test_packet: TestPacket,
) -> bool {
	for item in test_packet.items {
		if !serialize_integer(bit_writer, item, 0, math.max(i32)) {
			return false
		}
	}

	return true
}

desserialize_test_packet :: proc(
	bit_reader: ^Bit_Reader,
) -> (
	TestPacket,
	bool,
) {
	test_packet := TestPacket{}
	for i in 0 ..< len(test_packet.items) {
		item, ok := deserialize_integer(bit_reader, 0, math.max(i32))
		if !ok {
			return TestPacket{}, false
		}
		test_packet.items[i] = item
	}

	return test_packet, true
}

random_test_packet :: proc() -> TestPacket {
	test_packet := TestPacket{}
	for i in 0 ..< len(test_packet.items) {
		test_packet.items[i] = rand.int31()
	}
	return test_packet
}

Fragment_Packet :: struct {
	fragment_size: u32,
	crc32:         u32,
	sequence:      u16,
	packet_type:   Packet_Type,
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

// TODO(Thomas): A lot of functionality is missing, just sketching stuff out right now
advance_sequence :: proc(sequence_buffer: ^Sequence_Buffer) {
	sequence_buffer.current_sequence += 1
}

// TODO(Thomas): A lot of functionality missing, just sketching stuff out right now
receive_packet_fragments :: proc(
	sequence_buffer: ^Sequence_Buffer,
	fragment_packet: Fragment_Packet,
) {
	index := get_sequence_index(fragment_packet.sequence)

	if sequence_buffer.sequence[index] == ENTRY_SENTINEL_VALUE {
		entry := Entry {
			num_fragments      = fragment_packet.num_fragments,
			received_fragments = 0,
		}
		sequence_buffer.entries[index] = entry
	}
}

// TODO(Thomas) Everything
process_fragment :: proc() {

}

// TODO(Thomas) Everything
process_packet :: proc() {

}

split_packet_into_fragments :: proc(
	sequence: u16,
	packet_data: []u8,
	num_fragments: ^u32,
	allocator := context.temp_allocator,
) -> []Fragment_Packet {

	num_fragments^ = 0

	packet_size := u32(len(packet_data))
	assert(packet_size > 0)
	assert(packet_size < MAX_PACKET_SIZE)

	// Add one if MAX_FRAGMENT_SIZE does not evenly divide the packet size,
	// this is integer division we'll essentially get the floor value.
	// So we need one more fragment for the rest.
	num_fragments^ =
		packet_size / MAX_FRAGMENT_SIZE +
		((packet_size % MAX_FRAGMENT_SIZE == 0) ? 0 : 1)


	fragments := make([]Fragment_Packet, num_fragments^, allocator)

	for i in 0 ..< num_fragments^ {
		fragment_packet := Fragment_Packet{}
		fragments[i] = fragment_packet
	}

	return fragments
}

serialize_fragment_packet :: proc(
	bit_writer: ^Bit_Writer,
	fragment_packet: Fragment_Packet,
) -> bool {

	if !write_bits(bit_writer, fragment_packet.fragment_size, 32) {
		return false
	}

	if !write_bits(bit_writer, fragment_packet.crc32, 32) {
		return false
	}

	if !write_bits(bit_writer, u32(fragment_packet.sequence), 32) {
		return false
	}

	// NOTE(Thomas): This len(Packet_Type) - 1 trick only works if 
	// there is more than one variant in the Packet_Type enum
	if !write_bits(
		bit_writer,
		u32(fragment_packet.packet_type),
		len(Packet_Type) - 1,
	) {
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

	crc32, crc32_ok := read_bits(bit_reader, 32)
	if !crc32_ok {
		return Fragment_Packet{}, false
	}

	sequence, seq_ok := read_bits(bit_reader, 32)
	if !seq_ok {
		return Fragment_Packet{}, false
	}

	packet_type_int, packet_type_ok := read_bits(
		bit_reader,
		len(Packet_Type) - 1,
	)
	if !packet_type_ok {
		return Fragment_Packet{}, false
	}
	packet_type := Packet_Type(packet_type_int)

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
			crc32,
			u16(sequence),
			packet_type,
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
	equal_crc32 := packet_a.crc32 == packet_b.crc32
	equal_seq := packet_a.sequence == packet_b.sequence
	equal_packet_type := packet_a.packet_type == packet_b.packet_type
	equal_frag_id := packet_a.fragment_id == packet_b.fragment_id
	equal_num_fragments := packet_a.num_fragments == packet_b.num_fragments
	equal_data := bytes.compare(packet_a.data, packet_b.data) == 0
	return(
		equal_frag_size &&
		equal_crc32 &&
		equal_seq &&
		equal_packet_type &&
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
			crc32         = 72,
			sequence      = 42,
			fragment_id   = 12,
			num_fragments = 14,
			data          = fragment_data[:],
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
			crc32         = 72,
			sequence      = 42,
			fragment_id   = 12,
			num_fragments = 14,
			data          = fragment_data[:],
		}
		fragment_packet_b := Fragment_Packet {
			fragment_size = MAX_FRAGMENT_SIZE,
			crc32         = 73,
			sequence      = 42,
			fragment_id   = 12,
			num_fragments = 14,
			data          = fragment_data[:],
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
		crc32         = 72,
		sequence      = 42,
		packet_type   = Packet_Type.Fragment,
		fragment_id   = 12,
		num_fragments = 14,
		data          = fragment_data[:],
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
			crc32         = 72,
			sequence      = 42,
			packet_type   = Packet_Type.Fragment,
			fragment_id   = 12,
			num_fragments = 14,
			data          = fragment_data[:],
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
	seq_buffer := Sequence_Buffer{}
	for seq in seq_buffer.sequence {
		testing.expect_value(t, seq, 0)
	}

	init_sequence_buffer(&seq_buffer)

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

	test_packet := random_test_packet()
	serialize_ok := serialize_test_packet(&writer, test_packet)

	testing.expectf(
		t,
		serialize_ok,
		fmt.tprintf("Serializing test packet should be successful"),
	)

	deserialized_test_packet, deserialize_ok := desserialize_test_packet(
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
test_split_packet_into_fragments_exact :: proc(t: ^testing.T) {

	packet_size := 2048
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	num_fragments: u32 = 0

	fragments := split_packet_into_fragments(
		0,
		packet_data,
		&num_fragments,
		context.temp_allocator,
	)

	testing.expect_value(t, len(fragments), packet_size / MAX_FRAGMENT_SIZE)
}

@(test)
test_split_packet_into_fragments_one_rest :: proc(t: ^testing.T) {

	packet_size := 2049
	packet_data := make([]u8, packet_size, context.temp_allocator)
	defer free_all(context.temp_allocator)

	num_fragments: u32 = 0

	fragments := split_packet_into_fragments(
		0,
		packet_data,
		&num_fragments,
		context.temp_allocator,
	)

	testing.expect_value(
		t,
		len(fragments),
		(packet_size / MAX_FRAGMENT_SIZE) + 1,
	)
}
