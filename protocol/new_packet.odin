package protocol

import "base:runtime"
import "core:mem"

QOS :: enum {
	Best_Effort,
	Reliable,
}

Packet_Header :: struct {
	crc32:       u32,
	qos:         u32,
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

// ------------- Serializiation procedures -------------

@(require_results)
serialize_packet_header :: proc(bit_writer: ^Bit_Writer, packet_header: Packet_Header) -> bool {

	serialize_u32(bit_writer, packet_header.crc32) or_return

	// NOTE(Thomas): This len(QOS) - 1 trick only works if 
	// there is more than one variant in the QOS enum
	write_bits(bit_writer, u32(packet_header.qos), len(QOS) - 1) or_return

	serialize_u32(bit_writer, packet_header.packet_type) or_return
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

// ------------- Deserializiation procedures -------------

@(require_results)
deserialize_packet_header :: proc(bit_reader: ^Bit_Reader) -> (Packet_Header, bool) {

	crc32, crc32_ok := deserialize_u32(bit_reader)
	if !crc32_ok {
		return Packet_Header{}, false
	}

	qos, qos_ok := read_bits(bit_reader, len(QOS) - 1)
	if !qos_ok {
		return Packet_Header{}, false
	}

	packet_type, packet_type_ok := deserialize_u32(bit_reader)
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
			qos = u32(qos),
			packet_type = packet_type,
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

//// ------------- Utility procedures -------------
split_packet_into_fragments :: proc(
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
