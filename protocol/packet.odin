package protocol

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:testing"

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
}

Packet :: struct {
	header: Packet_Header,
	data:   []u8,
}

// TODO(Thomas): Make the fragment_size u16 instead
Fragment_Header :: struct {
	fragment_size: u32,
	fragment_id:   u8,
	num_fragments: u8,
}

Fragment :: struct {
	header: Fragment_Header,
	data:   []u8,
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

	serialize_packet_header(bit_writer, packet.header) or_return

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

	serialize_fragment_header(bit_writer, fragment.header) or_return

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
		log.error("failed to deserialize crc32")
		return Packet_Header{}, false
	}

	qos, qos_ok := read_bits(bit_reader, len(QOS) - 1)
	if !qos_ok {
		log.error("failed to deserialize qos")
		return Packet_Header{}, false
	}

	packet_type, packet_type_ok := deserialize_u32(bit_reader)
	if !packet_type_ok {
		log.error("failed to deserialize packet_type")
		return Packet_Header{}, false
	}

	data_length, data_length_ok := deserialize_u32(bit_reader)
	if !data_length_ok {
		log.error("failed to deserialize data_length")
		return Packet_Header{}, false
	}

	sequence, seq_ok := deserialize_u16(bit_reader)
	if !seq_ok {
		log.error("failed to deserialize sequence")
		return Packet_Header{}, false
	}


	return Packet_Header {
			crc32 = crc32,
			qos = u32(qos),
			packet_type = packet_type,
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
		log.error("failed to deserialize packet header")
		return Packet{}, false
	}

	if !read_align(bit_reader) {
		log.error("failed to read_align")
		return Packet{}, false
	}

	data, alloc_err := make([]u8, packet_header.data_length, allocator)
	assert(alloc_err == .None)
	if alloc_err != .None {
		log.error("alloc error: ", alloc_err)
	}

	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		log.error("failed to read bytes, len(data): ", len(data))
		return Packet{}, false
	}

	return Packet{packet_header, data}, true
}

@(require_results)
deserialize_fragment_header :: proc(bit_reader: ^Bit_Reader) -> (Fragment_Header, bool) {

	fragment_size, fragment_size_ok := deserialize_u32(bit_reader)
	if !fragment_size_ok {
		log.error("failed to deserialize fragment_size")
		return Fragment_Header{}, false
	}

	fragment_id, fragment_id_ok := deserialize_u8(bit_reader)
	if !fragment_id_ok {
		log.error("failed to deserialize fragment_id")
		return Fragment_Header{}, false
	}

	num_fragments, num_fragments_ok := deserialize_u8(bit_reader)
	if !num_fragments_ok {
		log.error("failed to deserialize num_fragments")
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
		log.error("failed to deserialize fragment_header")
		return Fragment{}, false
	}

	if !deserialize_align(bit_reader) {
		log.error("failed to deserialize_align")
		return Fragment{}, false
	}

	data, alloc_err := make([]u8, fragment_header.fragment_size, allocator)
	assert(alloc_err == .None)
	if alloc_err != .None {
		log.error("alloc error: ", alloc_err)
	}

	data_ok := read_bytes(bit_reader, data, u32(len(data)))
	if !data_ok {
		log.error("failed to read_bytes, len(data): ", len(data))
		return Fragment{}, false
	}

	fragment := Fragment {
		header = fragment_header,
		data   = data,
	}

	return fragment, true
}

// ------------- Utility procedures -------------

split_packet_into_fragments :: proc(
	packet_data: []u8,
	allocator: runtime.Allocator,
) -> []Fragment {
	packet_size := len(packet_data)
	assert(packet_size > 0)
	if packet_size <= 0 {
		log.error("packet_size <= 0")
	}

	assert(packet_size <= MAX_PACKET_SIZE)
	if packet_size > MAX_PACKET_SIZE {
		log.error("packet_size > MAX_PACKET_SIZE ")
	}

	fragment_size := min(packet_size, MAX_FRAGMENT_SIZE)
	num_fragments := (packet_size + MAX_FRAGMENT_SIZE - 1) / MAX_FRAGMENT_SIZE

	fragments, alloc_err := make([]Fragment, num_fragments, allocator)
	assert(alloc_err == .None)
	if alloc_err != .None {
		log.error("alloc error: ", alloc_err)
	}

	for &fragment, i in fragments {
		start := i * MAX_FRAGMENT_SIZE
		end := min(start + MAX_FRAGMENT_SIZE, packet_size)
		current_fragment_size := end - start

		fragment.data, alloc_err = make([]u8, current_fragment_size, allocator)
		assert(alloc_err == .None)
		if alloc_err != .None {
			log.error("alloc error: ", alloc_err)
		}
		mem.copy(&fragment.data[0], &packet_data[start], current_fragment_size)

		fragment.header = Fragment_Header {
			fragment_size = u32(current_fragment_size),
			fragment_id   = u8(i),
			num_fragments = u8(num_fragments),
		}
	}

	return fragments
}

@(require_results)
compare_packet :: proc(packet_a: Packet, packet_b: Packet) -> bool {
	equal_header := packet_a.header == packet_b.header
	equal_data := mem.compare(packet_a.data, packet_b.data) == 0
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
	equal_fragment_header := compare_fragment_header(fragment_a.header, fragment_b.header)
	equal_data := mem.compare(fragment_a.data, fragment_b.data) == 0
	return equal_fragment_header && equal_data

}

//// ------------- Tests -------------

@(test)
test_serialize_deserialize_packet_header :: proc(t: ^testing.T) {
	buffer := make([]u32, 100)
	defer delete(buffer)
	writer := create_writer(buffer)
	reader := create_reader(buffer)

	packet_header := Packet_Header {
		crc32       = 72,
		qos         = u32(QOS.Best_Effort),
		packet_type = 3,
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
		qos         = u32(QOS.Best_Effort),
		packet_type = 2,
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
		header = Fragment_Header {
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
test_split_packet_into_fragments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// Test case 1: Packet smaller than MAX_FRAGMENT_SIZE
	{
		packet := make([]u8, 512)
		for i in 0 ..< 512 do packet[i] = u8(i % 256)

		fragments := split_packet_into_fragments(packet, context.allocator)
		defer delete(fragments)

		testing.expect(t, len(fragments) == 1, "Expected 1 fragment for small packet")
		testing.expect(t, fragments[0].header.fragment_size == 512, "Incorrect fragment size")
		testing.expect(t, fragments[0].header.fragment_id == 0, "Incorrect fragment ID")
		testing.expect(t, fragments[0].header.num_fragments == 1, "Incorrect number of fragments")
		testing.expect(
			t,
			mem.compare(fragments[0].data, packet) == 0,
			"Fragment data doesn't match packet data",
		)
	}

	// Test case 2: Packet exactly MAX_FRAGMENT_SIZE
	{
		packet := make([]u8, MAX_FRAGMENT_SIZE)
		for i in 0 ..< MAX_FRAGMENT_SIZE do packet[i] = u8(i % 256)

		fragments := split_packet_into_fragments(packet, context.allocator)
		defer delete(fragments)

		testing.expect(t, len(fragments) == 1, "Expected 1 fragment for MAX_FRAGMENT_SIZE packet")
		testing.expect(
			t,
			fragments[0].header.fragment_size == MAX_FRAGMENT_SIZE,
			"Incorrect fragment size",
		)
		testing.expect(t, fragments[0].header.fragment_id == 0, "Incorrect fragment ID")
		testing.expect(t, fragments[0].header.num_fragments == 1, "Incorrect number of fragments")
		testing.expect(
			t,
			mem.compare(fragments[0].data, packet) == 0,
			"Fragment data doesn't match packet data",
		)
	}

	// Test case 3: Packet larger than MAX_FRAGMENT_SIZE but not a multiple
	{
		packet := make([]u8, MAX_FRAGMENT_SIZE + 512)
		for i in 0 ..< len(packet) do packet[i] = u8(i % 256)

		fragments := split_packet_into_fragments(packet, context.allocator)
		defer delete(fragments)

		testing.expect(t, len(fragments) == 2, "Expected 2 fragments for large packet")
		testing.expect(
			t,
			fragments[0].header.fragment_size == MAX_FRAGMENT_SIZE,
			"Incorrect first fragment size",
		)
		testing.expect(
			t,
			fragments[1].header.fragment_size == 512,
			"Incorrect second fragment size",
		)
		testing.expect(t, fragments[0].header.fragment_id == 0, "Incorrect first fragment ID")
		testing.expect(t, fragments[1].header.fragment_id == 1, "Incorrect second fragment ID")
		testing.expect(t, fragments[0].header.num_fragments == 2, "Incorrect number of fragments")
		testing.expect(t, fragments[1].header.num_fragments == 2, "Incorrect number of fragments")
		testing.expect(
			t,
			mem.compare(fragments[0].data, packet[:MAX_FRAGMENT_SIZE]) == 0,
			"First fragment data mismatch",
		)
		testing.expect(
			t,
			mem.compare(fragments[1].data, packet[MAX_FRAGMENT_SIZE:]) == 0,
			"Second fragment data mismatch",
		)
	}

	// Test case 4: Packet size at MAX_PACKET_SIZE - 1
	{
		packet := make([]u8, MAX_PACKET_SIZE - 1)
		for i in 0 ..< len(packet) do packet[i] = u8(i % 256)

		fragments := split_packet_into_fragments(packet, context.allocator)
		defer delete(fragments)

		expected_fragments := (MAX_PACKET_SIZE - 1 + MAX_FRAGMENT_SIZE - 1) / MAX_FRAGMENT_SIZE
		testing.expect(
			t,
			len(fragments) == expected_fragments,
			"Incorrect number of fragments for max packet size",
		)

		for i in 0 ..< len(fragments) {
			testing.expect(t, fragments[i].header.fragment_id == u8(i), "Incorrect fragment ID")
			testing.expect(
				t,
				fragments[i].header.num_fragments == u8(expected_fragments),
				"Incorrect number of fragments",
			)

			start := i * MAX_FRAGMENT_SIZE
			end := min(start + MAX_FRAGMENT_SIZE, len(packet))
			testing.expect(
				t,
				fragments[i].header.fragment_size == u32(end - start),
				"Incorrect fragment size",
			)
			testing.expect(
				t,
				mem.compare(fragments[i].data, packet[start:end]) == 0,
				"Fragment data mismatch",
			)
		}
	}
}
