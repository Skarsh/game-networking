package protocol

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:math"
import "core:testing"

MAX_FRAGMENTS_PER_PACKET :: 256
MAX_FRAGMENT_SIZE :: 1024
MAX_PACKET_SIZE :: MAX_FRAGMENTS_PER_PACKET * MAX_FRAGMENT_SIZE

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

Realtime_Packet_Type :: enum {
	Test_A,
	Test_B,
	Test_C,
}

Packet_Type :: enum {
	Realtime,
	Chunk,
}

Packet_Header :: struct {
	crc32:       u32,
	packet_type: i32,
	data_length: u32,
	sequence:    u16,
}

Packet :: struct {
	packet_header: Packet_Header,
	data:          []u8,
}

Realtime_Packet :: struct {
	packet_type: i32,
	data_length: u32,
	is_fragment: bool,
	data:        []u8,
}

Fragment :: struct {
	fragment_size: u32,
	fragment_id:   u8,
	num_fragments: u8,
	data:          []u8,
}

Fragment_Entry :: struct {
	sequence:           u16,
	num_fragments:      u8,
	received_fragments: u8,
	fragments:          [][]u8,
}

Complete_Entry :: struct {
	sequence: u16,
	data:     []u8,
}

Realtime_Packet_Entry :: struct {
	packet_type: Realtime_Packet_Type,
	entry:       union {
		Complete_Entry,
		Fragment_Entry,
	},
}


Realtime_Packet_Buffer :: struct {
	current_sequence: u32,
	entries:          [256]Realtime_Packet_Entry,
}

// ------------- Serializiation procedures -------------

@(require_results)
serialize_packet_header :: proc(bit_writer: ^Bit_Writer, packet_header: Packet_Header) -> bool {

	write_bits(bit_writer, packet_header.crc32, 32) or_return

	// NOTE(Thomas): This len(Packet_Type) - 1 trick only works if 
	// there is more than one variant in the Packet_Type enum
	write_bits(bit_writer, u32(packet_header.packet_type), len(Packet_Type) - 1) or_return

	write_bits(bit_writer, u32(packet_header.data_length), 32) or_return

	write_bits(bit_writer, u32(packet_header.sequence), 16) or_return

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
serialize_realtime_packet :: proc(
	bit_writer: ^Bit_Writer,
	realtime_packet: Realtime_Packet,
) -> bool {
	// NOTE(Thomas): This len(Packet_Type) - 1 trick only works if 
	// there is more than one variant in the Packet_Type enum
	write_bits(
		bit_writer,
		u32(realtime_packet.packet_type),
		len(Realtime_Packet_Type) - 1,
	) or_return

	write_bits(bit_writer, realtime_packet.data_length, 32) or_return

	serialize_bool(bit_writer, realtime_packet.is_fragment) or_return

	// Ensure we're aligned with next byte boundary
	serialize_align(bit_writer) or_return

	serialize_bytes(bit_writer, realtime_packet.data) or_return

	return true
}

@(require_results)
serialize_fragment :: proc(bit_writer: ^Bit_Writer, fragment: Fragment) -> bool {
	write_bits(bit_writer, fragment.fragment_size, 32) or_return

	write_bits(bit_writer, u32(fragment.fragment_id), 8) or_return

	write_bits(bit_writer, u32(fragment.num_fragments), 8) or_return

	// Ensure we're aligned with next byte boundary
	serialize_align(bit_writer) or_return

	serialize_bytes(bit_writer, fragment.data) or_return

	return true
}

// ------------- Deserializiation procedures -------------

@(require_results)
deserialize_packet_header :: proc(bit_reader: ^Bit_Reader) -> (Packet_Header, bool) {

	crc32, crc32_ok := read_bits(bit_reader, 32)
	if !crc32_ok {
		return Packet_Header{}, false
	}

	packet_type, packet_type_ok := read_bits(bit_reader, len(Packet_Type) - 1)
	if !packet_type_ok {
		return Packet_Header{}, false
	}

	data_length, data_length_ok := read_bits(bit_reader, 32)
	if !data_length_ok {
		return Packet_Header{}, false
	}

	sequence, seq_ok := read_bits(bit_reader, 16)
	if !seq_ok {
		return Packet_Header{}, false
	}

	return Packet_Header {
			crc32 = crc32,
			packet_type = i32(packet_type),
			data_length = data_length,
			sequence = u16(sequence),
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
deserialize_realtime_packet :: proc(
	bit_reader: ^Bit_Reader,
	allocator: runtime.Allocator,
) -> (
	Realtime_Packet,
	bool,
) {

	packet_type, packet_type_ok := read_bits(bit_reader, len(Realtime_Packet_Type) - 1)
	if !packet_type_ok {
		return Realtime_Packet{}, false
	}

	data_length, data_length_ok := read_bits(bit_reader, 32)
	if !data_length_ok {
		return Realtime_Packet{}, false
	}

	is_fragment, is_fragment_ok := deserialize_bool(bit_reader)
	if !is_fragment_ok {
		return Realtime_Packet{}, false
	}

	if !deserialize_align(bit_reader) {
		return Realtime_Packet{}, false
	}

	data := make([]u8, data_length, allocator)

	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		return Realtime_Packet{}, false
	}

	return Realtime_Packet {
			packet_type = i32(packet_type),
			data_length = data_length,
			is_fragment = is_fragment,
			data = data,
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

	fragment_size, fragment_size_ok := read_bits(bit_reader, 32)
	if !fragment_size_ok {
		return Fragment{}, false
	}

	fragment_id, fragment_id_ok := read_bits(bit_reader, 8)
	if !fragment_id_ok {
		return Fragment{}, false
	}

	num_fragments, num_fragments_ok := read_bits(bit_reader, 8)
	if !num_fragments_ok {
		return Fragment{}, false
	}

	if !deserialize_align(bit_reader) {
		return Fragment{}, false
	}

	data := make([]u8, fragment_size, allocator)
	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		return Fragment{}, false
	}

	return Fragment {
			fragment_size = fragment_size,
			fragment_id = u8(fragment_id),
			num_fragments = u8(num_fragments),
			data = data,
		},
		true
}

@(require_results)
process_packet :: proc(
	realtime_packet_buffer: ^Realtime_Packet_Buffer,
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
	reader := create_reader(words)

	packet, packet_ok := deserialize_packet(&reader, allocator)
	if !packet_ok {
		return false
	}

	// TODO(Thomas): Deal with crc32 calculation properly and compare the 
	// Packet crc32 to the one we've calculated here
	protocol_id := PROTOCOL_ID
	protocol_id_bytes := transmute([4]u8)protocol_id
	crc32 := calculate_crc32(protocol_id_bytes[:])

	// Check which packet type this is
	switch Packet_Type(packet.packet_header.packet_type) {
	case .Realtime:
		realtime_packet, realtime_packet_ok := deserialize_realtime_packet(&reader, allocator)
		if !realtime_packet_ok {
			return false
		}

		if realtime_packet.is_fragment {
			// TODO(Thomas): Process the fragment here
			fragment, fragment_ok := deserialize_fragment(&reader, allocator)
			if !fragment_ok {
				return false
			}
		} else {
			// TODO(Thomas): This is a complete Realtime packet, do that processing here
		}

	case .Chunk:
	}

	return true
}

@(require_results)
compare_packet :: proc(packet_a: Packet, packet_b: Packet) -> bool {
	equal_header := packet_a.packet_header == packet_b.packet_header
	equal_data := bytes.compare(packet_a.data, packet_b.data) == 0
	return equal_header && equal_data
}

@(require_results)
compare_realtime_packet :: proc(packet_a: Realtime_Packet, packet_b: Realtime_Packet) -> bool {
	equal_packet_type := packet_a.packet_type == packet_b.packet_type
	equal_data_length := packet_a.data_length == packet_b.data_length
	equal_is_fragment := packet_a.is_fragment == packet_b.is_fragment
	equal_data := bytes.compare(packet_a.data, packet_b.data) == 0
	return equal_packet_type && equal_data_length && equal_is_fragment && equal_data
}

@(require_results)
compare_fragment :: proc(fragment_a: Fragment, fragment_b: Fragment) -> bool {
	equal_fragment_size := fragment_a.fragment_size == fragment_b.fragment_size
	equal_fragment_id := fragment_a.fragment_id == fragment_b.fragment_id
	equal_num_fragments := fragment_a.num_fragments == fragment_b.num_fragments
	equal_data := bytes.compare(fragment_a.data, fragment_b.data) == 0
	return equal_fragment_size && equal_fragment_id && equal_num_fragments && equal_data

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
		packet_type = i32(Packet_Type.Realtime),
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
		packet_type = i32(Packet_Type.Realtime),
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
test_serialize_deserialize_realtime_packet :: proc(t: ^testing.T) {
	buffer := make([]u32, 100, context.temp_allocator)
	defer free_all(context.temp_allocator)

	writer := create_writer(buffer)
	reader := create_reader(buffer)

	// TODO(Thomas): Instead of some random data this should be 
	// actual Test_A packet data
	data := make([]u8, 100, context.temp_allocator)
	for &b in data {
		b = 42
	}

	realtime_packet := Realtime_Packet {
		packet_type = i32(Realtime_Packet_Type.Test_A),
		data_length = u32(len(data)),
		is_fragment = false,
		data        = data,
	}

	testing.expectf(
		t,
		serialize_realtime_packet(&writer, realtime_packet),
		"serialize_realtime_packet should be successful",
	)

	testing.expectf(t, flush_bits(&writer), "flush_bits should be successful")

	des_realtime_packet, des_realtime_packet_ok := deserialize_realtime_packet(
		&reader,
		context.temp_allocator,
	)

	testing.expectf(t, des_realtime_packet_ok, "deserialize_realtime_packet should be successful")

	testing.expectf(
		t,
		compare_realtime_packet(des_realtime_packet, realtime_packet),
		fmt.tprintf("expected %v to be equal to %v", realtime_packet, des_realtime_packet),
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
		fragment_size = u32(len(data)),
		fragment_id   = 14,
		num_fragments = 53,
		data          = data,
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
